import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors

public enum CaptureError: LocalizedError {
    case micDenied
    case screenRecordingNeedsGrant
    case noDisplay
    case engineNotReady
    case captureTargetUnavailable
    case processTapUnavailable(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .micDenied:
            return "Microphone access was denied. Enable it in System Settings ▸ Privacy & Security ▸ Microphone, then try again."
        case .screenRecordingNeedsGrant:
            return "Capture needs the Screen Recording permission. Enable Said in System Settings ▸ Privacy & Security ▸ Screen Recording, then quit and relaunch the app."
        case .noDisplay:
            return "No display was available to attach the capture stream to."
        case .engineNotReady:
            return "The transcription model is not loaded yet."
        case .captureTargetUnavailable:
            return "The chosen visual-capture target (window/app/display) is no longer available."
        case .processTapUnavailable(let status):
            return "Could not create the system-audio tap (Core Audio status \(status)). "
                 + "Falling back to the ScreenCaptureKit path."
        }
    }
}

// MARK: - Sample receiver (capture → sink, or capture → mixer port)

/// A destination for 16 kHz mono Float32 samples. Capture sources push into one of these. For
/// single-source recording it's the `SampleSink` directly (byte-identical to before); for the
/// Mic+System mode it's an `AudioMixer` port that sums the two streams before the shared sink.
public protocol SampleReceiver: AnyObject, Sendable {
    func append(_ samples: [Float])
}

/// Forwards one sample stream to two destinations, in order. Used only when a screen recording is
/// live: the samples go to the transcription sink AND into the video's audio track. With no screen
/// recording there is no tee at all, so the capture path stays byte-identical.
public final class SampleTee: SampleReceiver, @unchecked Sendable {
    private let primary: any SampleReceiver
    private let secondary: any SampleReceiver
    public init(_ primary: any SampleReceiver, _ secondary: any SampleReceiver) {
        self.primary = primary
        self.secondary = secondary
    }
    public func append(_ samples: [Float]) {
        primary.append(samples)
        secondary.append(samples)
    }
}

// MARK: - Shared sample sink (thread-safe accumulating buffer)

/// A thread-safe buffer of 16 kHz mono Float32 PCM samples shared by the active capture source and
/// the streaming transcription pipeline. Audio callbacks `append`.
///
/// There are two readers, and the difference between them matters (Phase 3, §5.3):
/// `snapshot()` copies the WHOLE recording and is for the things that genuinely need it once — the
/// final pass, the `audio.m4a` write, the diarization buffer. `newSamples(after:)` returns only what
/// has arrived since the caller last asked, and is what a streaming engine consumes.
public final class SampleSink: SampleReceiver, @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var buffer: [Float] = []

    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        buffer.append(contentsOf: samples)
        lock.unlock()
    }

    public func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    // MARK: Incremental read (Phase 3, §5.3)

    /// Samples appended since `index`, plus the index to pass next time.
    ///
    /// **This is the fix for the worst performance defect in the codebase.** The Whisper streamer
    /// re-`snapshot()`s the ENTIRE growing buffer roughly once a second. Swift arrays are
    /// copy-on-write, so the copy is not paid at the `snapshot()` — it is paid on the very next
    /// `append`, which finds the buffer shared and duplicates all of it. At 16 kHz Float32 a
    /// two-hour session is ~460 MB, so that is a 460 MB memcpy per second, growing linearly with
    /// session length, on the audio callback's path.
    ///
    /// An engine that consumes incremental windows reads only what is new, so the cost per pass is
    /// proportional to the AUDIO ARRIVING rather than to the session so far — flat, not linear.
    /// `snapshot()` is left exactly as it was for the final pass, the audio write and the
    /// diarization snapshot, which genuinely do want the whole buffer, once.
    ///
    /// Clamps rather than traps if `index` is out of range: a `reset()` between two reads (a new
    /// session starting) leaves a stale index pointing past the end, and that must resynchronise
    /// silently rather than crash a recording.
    public func newSamples(after index: Int) -> (samples: [Float], next: Int) {
        lock.lock(); defer { lock.unlock() }
        let from = min(max(0, index), buffer.count)
        guard from < buffer.count else { return ([], buffer.count) }
        let slice = Array(buffer[from..<buffer.count])
        maxIncrementalRead = max(maxIncrementalRead, slice.count)
        return (slice, buffer.count)
    }

    private var maxIncrementalRead: Int = 0

    /// The largest single `newSamples(after:)` result this sink has ever returned.
    ///
    /// Instrumentation, not behaviour: `--selftest-pause` asserts that no read ever hands back the
    /// whole session again, which is what proves the full-buffer copy is actually gone rather than
    /// merely moved. (Not `--selftest-stream`: that mode drives the WHISPER path, which by design
    /// still snapshots, so it could never exercise this reader.) Reset by `reset()` with the buffer.
    ///
    /// Read under the lock like everything else here. A `public private(set) var` would have been a
    /// plain unsynchronised read racing the writer above — which is exactly the exception an
    /// `@unchecked Sendable` promise must not carry, however harmless a torn `Int` looks.
    public var largestIncrementalRead: Int {
        lock.lock(); defer { lock.unlock() }
        return maxIncrementalRead
    }

    public func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        maxIncrementalRead = 0
        lock.unlock()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    /// True when the most recent `window` samples are ALL exactly 0 — i.e. the OS handed us
    /// zero-filled buffers rather than quiet audio. Digital silence is distinct from a quiet
    /// room (a live mic always carries a nonzero noise floor), so this specifically catches
    /// "the capture is running but carrying nothing" — the failure mode where a session records
    /// for minutes and saves nothing but `[BLANK_AUDIO]`.
    ///
    /// Returns false until at least `window` samples exist, so it can't fire at startup.
    public func recentAllZero(_ window: Int = 16_000) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard buffer.count >= window else { return false }
        for i in (buffer.count - window)..<buffer.count where buffer[i] != 0 { return false }
        return true
    }

    /// RMS level of the most recent `window` samples, scaled to ~0…1 for the live meter.
    /// Cheap; safe to call ~10–15 Hz from the UI.
    public func recentRMS(_ window: Int = 2_400) -> Float {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return 0 }
        let n = min(window, buffer.count)
        var sum: Float = 0
        for i in (buffer.count - n)..<buffer.count {
            let s = buffer[i]
            sum += s * s
        }
        let rms = (sum / Float(n)).squareRoot()
        return min(1, rms * 8)   // gentle gain; speech RMS ~0.02–0.15
    }
}

// MARK: - Resampler to 16 kHz mono Float32

/// Converts an `AVAudioPCMBuffer` of ANY format (mic hardware rate, or system-audio
/// 48 kHz stereo) into 16 kHz mono Float32 samples — the exact format WhisperKit needs.
/// Getting this wrong is the #1 cause of empty/garbled transcripts.
///
/// One converter instance is kept alive per capture so AVAudioConverter's internal
/// resampler state stays continuous across buffers; it is recreated only if the input
/// format changes. Not thread-safe by design: each capture owns its own resampler and
/// feeds it from a single (audio) thread.
public final class Resampler16k {
    public init() {}

    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    public func resample(_ input: AVAudioPCMBuffer) -> [Float]? {
        guard input.frameLength > 0 else { return [] }

        if converter == nil || inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: Self.outputFormat)
            inputFormat = input.format
        }
        guard let converter else { return nil }

        let ratio = Self.outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inStatus in
            if fed {
                inStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inStatus.pointee = .haveData
            return input
        }

        if status == .error || conversionError != nil { return nil }
        guard output.frameLength > 0, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

// MARK: - CMSampleBuffer (ScreenCaptureKit audio) → AVAudioPCMBuffer

extension CMSampleBuffer {
    /// Wraps an audio sample buffer's PCM data as an `AVAudioPCMBuffer` without copying.
    /// ScreenCaptureKit delivers deinterleaved Float32. The returned buffer (and its
    /// underlying pointers) is only valid while `self` is alive — copy the floats out
    /// (the resampler does) before the buffer escapes the delegate callback.
    public var asPCMBuffer: AVAudioPCMBuffer? {
        let result = try? withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let asbd = formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(
                    standardFormatWithSampleRate: asbd.mSampleRate,
                    channels: asbd.mChannelsPerFrame
                  )
            else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
        return result ?? nil
    }

    /// The video frame (ScreenCaptureKit `.screen` output) as a `CGImage`, or nil.
    var videoCGImage: CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(self) else { return nil }
        return CGImage.fromPixelBuffer(pixelBuffer)
    }
}

// MARK: - CGImage helpers (screen-recording preview)

extension CGImage {
    /// Wrap a CoreVideo pixel buffer (BGRA from ScreenCaptureKit) as a CGImage.
    public static func fromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return image
    }

    /// A downscaled copy whose longest side is `maxDim` (for the live UI). Keeps memory bounded.
    public func thumbnail(maxDim: CGFloat) -> CGImage? {
        let w = CGFloat(width), h = CGFloat(height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxDim / max(w, h))
        let tw = max(1, Int((w * scale).rounded()))
        let th = max(1, Int((h * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }
}
