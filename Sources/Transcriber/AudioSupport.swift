import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors

enum CaptureError: LocalizedError {
    case micDenied
    case screenRecordingNeedsGrant
    case noDisplay
    case engineNotReady
    case captureTargetUnavailable

    var errorDescription: String? {
        switch self {
        case .micDenied:
            return "Microphone access was denied. Enable it in System Settings ▸ Privacy & Security ▸ Microphone, then try again."
        case .screenRecordingNeedsGrant:
            return "Capture needs the Screen Recording permission. Enable Transcriber in System Settings ▸ Privacy & Security ▸ Screen Recording, then quit and relaunch the app."
        case .noDisplay:
            return "No display was available to attach the capture stream to."
        case .engineNotReady:
            return "The transcription model is not loaded yet."
        case .captureTargetUnavailable:
            return "The chosen visual-capture target (window/app/display) is no longer available."
        }
    }
}

// MARK: - Sample receiver (capture → sink, or capture → mixer port)

/// A destination for 16 kHz mono Float32 samples. Capture sources push into one of these. For
/// single-source recording it's the `SampleSink` directly (byte-identical to before); for the
/// Mic+System mode it's an `AudioMixer` port that sums the two streams before the shared sink.
protocol SampleReceiver: AnyObject, Sendable {
    func append(_ samples: [Float])
}

// MARK: - Shared sample sink (thread-safe accumulating buffer)

/// A thread-safe buffer of 16 kHz mono Float32 PCM samples shared by the active
/// capture source and the streaming transcription pipeline. Audio callbacks
/// `append`; the pipeline `snapshot`s the whole recording each pass.
final class SampleSink: SampleReceiver, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Float] = []

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        buffer.append(contentsOf: samples)
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    /// RMS level of the most recent `window` samples, scaled to ~0…1 for the live meter.
    /// Cheap; safe to call ~10–15 Hz from the UI.
    func recentRMS(_ window: Int = 2_400) -> Float {
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
final class Resampler16k {
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func resample(_ input: AVAudioPCMBuffer) -> [Float]? {
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
    var asPCMBuffer: AVAudioPCMBuffer? {
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

// MARK: - CGImage helpers (visual capture)

extension CGImage {
    /// Wrap a CoreVideo pixel buffer (BGRA from ScreenCaptureKit) as a CGImage.
    static func fromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return image
    }

    /// PNG-encode this image.
    func pngData() -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, self, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// A standalone bitmap copy that does NOT reference the source's backing store. Needed before
    /// retaining a ScreenCaptureKit frame past the delegate callback — its IOSurface gets recycled.
    func detachedCopy() -> CGImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// A downscaled copy whose longest side is `maxDim` (for the live UI). Keeps memory bounded.
    func thumbnail(maxDim: CGFloat) -> CGImage? {
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
