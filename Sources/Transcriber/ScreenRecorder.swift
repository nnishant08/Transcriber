import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreGraphics
import AppKit

// MARK: - Target & quality (per-session, persisted)

/// What the screen recorder points at. Persisted as a compact string, like every other setting.
enum ScreenTarget: Hashable, Codable {
    case mainDisplay
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case app(String)             // bundle identifier

    var persisted: String {
        switch self {
        case .mainDisplay: return "main"
        case .display(let id): return "display:\(id)"
        case .window(let id): return "window:\(id)"
        case .app(let b): return "app:\(b)"
        }
    }
    init(persisted: String) {
        if persisted == "main" { self = .mainDisplay; return }
        let parts = persisted.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "display": self = .display(CGDirectDisplayID(parts.last.flatMap { UInt32($0) } ?? CGMainDisplayID()))
        case "window": self = .window(CGWindowID(parts.last.flatMap { UInt32($0) } ?? 0))
        case "app": self = .app(parts.count > 1 ? parts[1] : "")
        default: self = .mainDisplay
        }
    }
}

/// A selectable target for the Settings picker, populated live from `SCShareableContent`.
struct ScreenTargetOption: Identifiable, Hashable {
    let id: String
    let label: String
    let target: ScreenTarget
    static func == (a: ScreenTargetOption, b: ScreenTargetOption) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Recording size/rate preset. A screen recording is the biggest file this app writes, so the
/// default deliberately sits at 1080p/24 — sharp enough to read code and slides, roughly a tenth
/// the bytes of native Retina at 60 fps.
enum ScreenQuality: String, CaseIterable, Identifiable, Codable {
    case compact
    case balanced
    case sharp

    var id: String { rawValue }
    var label: String {
        switch self {
        case .compact: return "Compact — 720p · 15 fps"
        case .balanced: return "Balanced — 1080p · 24 fps"
        case .sharp: return "Sharp — 1440p · 30 fps"
        }
    }
    var shortLabel: String {
        switch self {
        case .compact: return "720p"
        case .balanced: return "1080p"
        case .sharp: return "1440p"
        }
    }
    /// Long edge of the encoded video (the capture is scaled to fit, never upscaled).
    var maxLongEdge: Int {
        switch self {
        case .compact: return 1280
        case .balanced: return 1920
        case .sharp: return 2560
        }
    }
    var fps: Int32 {
        switch self {
        case .compact: return 15
        case .balanced: return 24
        case .sharp: return 30
        }
    }
    /// H.264 average bitrate for the encoded size. Screen content is mostly static, so these are
    /// generous for text and cheap in practice (the encoder spends far less on unchanged frames).
    func bitrate(width: Int, height: Int) -> Int {
        let pixels = Double(width * height)
        let perPixel: Double = 0.09        // bits per pixel per frame, tuned for screen content
        return Int(pixels * perPixel * Double(fps))
    }
}

/// What a finished screen recording produced.
struct ScreenRecordingResult: Sendable {
    var url: URL
    var duration: TimeInterval
    var byteSize: Int64
    var width: Int
    var height: Int
    var frameCount: Int
}

// MARK: - ScreenRecorder

/// Records the screen to an H.264 `.mp4` **with the session's audio muxed in live**, on the same
/// pause-compressed clock every transcript timestamp uses.
///
/// Three rules make it line up with the transcript, which is the whole point of recording it here
/// rather than in QuickTime:
///
/// 1. **One clock.** Video frames are stamped `CACurrentMediaTime() - t0 - pausedTime`, i.e. the
///    `SessionClock` time. A pause removes time from the audio, so it must remove the same time
///    from the video, or every `[mm:ss]` in the transcript would drift by the length of the pause.
/// 2. **The audio is the session's audio.** The recorder is a `SampleReceiver`: the same 16 kHz mono
///    stream that feeds transcription is encoded into the video's audio track (AAC). No second
///    capture, no second permission, no re-sync — and no giant post-hoc remux at save time.
/// 3. **Silence is not a gap.** ScreenCaptureKit only delivers frames when pixels change, so a
///    static screen produces no samples. `finish()` ends the session at the true session length, so
///    the last frame is held to the end and the file's duration matches the transcript.
///
/// All mutable state is confined to `queue`; callbacks out (preview/stopped) hop to the main actor.
final class ScreenRecorder: NSObject, SampleReceiver, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let outputURL: URL
    let target: ScreenTarget
    let quality: ScreenQuality

    private let queue = DispatchQueue(label: "com.nikhil.transcriber.screenrec")
    private var stream: SCStream?
    private var writer: ScreenWriter?
    private var t0: TimeInterval = 0
    private var paused = false
    private var pausedOffset: TimeInterval = 0
    private var pauseBegan: TimeInterval = 0
    private var stopped = false
    private var lastPreviewAt: TimeInterval = -1
    private(set) var pixelSize: (width: Int, height: Int) = (0, 0)

    /// A downscaled frame for the live UI (~1 Hz). Delivered on the main actor.
    var onPreview: ((NSImage) -> Void)?
    /// The capture stopped on its own (window closed, display disconnected). Delivered on the main actor.
    var onStopped: ((String) -> Void)?

    init(target: ScreenTarget, quality: ScreenQuality, outputURL: URL) {
        self.target = target
        self.quality = quality
        self.outputURL = outputURL
    }

    // MARK: Lifecycle

    /// Build the capture + the writer and start recording. `t0` is the session clock origin, shared
    /// with the audio buffer and every transcript timestamp.
    func start(t0: TimeInterval) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            NSLog("[ScreenRec] shareable content failed — Screen Recording likely not granted: \(error)")
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            throw CaptureError.screenRecordingNeedsGrant
        }

        let filter = try makeFilter(content: content)
        let (w, h) = encodedSize(content: content)
        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: quality.fps)
        config.showsCursor = true            // a screen recording without the pointer is worthless
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        // Audio rides the transcription pipeline (this object is a SampleReceiver), so the stream
        // itself stays video-only: no second audio path, no interference with the process tap.
        config.capturesAudio = false

        let writer = try ScreenWriter(url: outputURL, width: w, height: h, quality: quality)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        queue.sync {
            self.t0 = t0
            self.paused = false
            self.pausedOffset = 0
            self.stopped = false
            self.lastPreviewAt = -1
            self.writer = writer
            self.pixelSize = (w, h)
        }
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            // Leave nothing behind: the writer has already created the output file.
            self.stream = nil
            queue.sync { self.writer = nil }
            _ = await writer.finish(endingAt: 0)
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        NSLog("[ScreenRec] started \(w)×\(h) @\(quality.fps)fps → \(outputURL.lastPathComponent)")
    }

    /// Mirror the session's pause. Paused time is removed from the video's timeline exactly as it is
    /// removed from the audio, so the two never drift apart.
    func setPaused(_ value: Bool, totalPaused: TimeInterval) {
        queue.async { [self] in
            if value, !paused { pauseBegan = CACurrentMediaTime() }
            paused = value
            pausedOffset = totalPaused
        }
    }

    /// Stop capturing and finalize the file. Returns nil if nothing usable was written.
    func finish() async -> ScreenRecordingResult? {
        if let s = stream {
            stream = nil
            try? s.removeStreamOutput(self, type: .screen)
            try? await s.stopCapture()
        }
        let (writer, endTime) = queue.sync { () -> (ScreenWriter?, TimeInterval) in
            stopped = true
            let w = self.writer
            self.writer = nil
            return (w, sessionTime())
        }
        guard let writer else { return nil }
        let result = await writer.finish(endingAt: endTime)
        if let result { NSLog("[ScreenRec] wrote \(result.frameCount) frames, \(String(format: "%.1f", result.duration))s, \(result.byteSize / 1_048_576) MB") }
        return result
    }

    // MARK: Audio in (SampleReceiver — the session's own 16 kHz mono stream)

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            guard !stopped, let writer else { return }
            writer.appendAudio(samples)
        }
    }

    // MARK: SCStreamOutput / delegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, !paused, let writer else { return }
        guard isComplete(sampleBuffer), let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = sessionTime()
        writer.appendVideo(pixels, at: t)

        // Live preview for the recording UI, ~1 Hz and downscaled — cheap enough to run beside the
        // encoder, and the only way the user can tell WHAT is being recorded without leaving the app.
        if onPreview != nil, t - lastPreviewAt >= 1.0 {
            lastPreviewAt = t
            if let cg = CGImage.fromPixelBuffer(pixels)?.thumbnail(maxDim: 420) {
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                DispatchQueue.main.async { [weak self] in self?.onPreview?(image) }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[ScreenRec] stream stopped with error: \(error)")
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in self?.onStopped?(message) }
    }

    // MARK: Internals (all on `queue`)

    /// Session time right now: wall clock since T0, minus every paused stretch (including the one
    /// currently in progress).
    private func sessionTime() -> TimeInterval {
        let now = CACurrentMediaTime()
        let offset = paused ? pausedOffset + max(0, now - pauseBegan) : pausedOffset
        return max(0, now - t0 - offset)
    }

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    private func makeFilter(content: SCShareableContent) throws -> SCContentFilter {
        guard let anyDisplay = content.displays.first else { throw CaptureError.noDisplay }
        let ownBundle = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundle }
        func mainDisplay() -> SCDisplay { content.displays.first { $0.displayID == CGMainDisplayID() } ?? anyDisplay }
        // Said's own windows are excluded so a recording of "the screen" isn't a recording of itself.
        func displayFilter(_ d: SCDisplay) -> SCContentFilter { SCContentFilter(display: d, excludingWindows: ownWindows) }

        switch target {
        case .mainDisplay:
            return displayFilter(mainDisplay())
        case .display(let id):
            return displayFilter(content.displays.first { $0.displayID == id } ?? mainDisplay())
        case .window(let id):
            if let win = content.windows.first(where: { $0.windowID == id }) {
                return SCContentFilter(desktopIndependentWindow: win)
            }
            NSLog("[ScreenRec] target window \(id) is gone — recording the main display instead")
            return displayFilter(mainDisplay())
        case .app(let bundle):
            if let app = content.applications.first(where: { $0.bundleIdentifier == bundle }) {
                return SCContentFilter(display: mainDisplay(), including: [app], exceptingWindows: [])
            }
            NSLog("[ScreenRec] target app \(bundle) is gone — recording the main display instead")
            return displayFilter(mainDisplay())
        }
    }

    /// The encoded pixel size: the source's own size scaled down to the quality preset (never up),
    /// rounded to even numbers (H.264 requires it).
    private func encodedSize(content: SCShareableContent) -> (Int, Int) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var w: CGFloat = 1920, h: CGFloat = 1080

        if case .window(let id) = target, let win = content.windows.first(where: { $0.windowID == id }) {
            w = win.frame.width * scale; h = win.frame.height * scale
        } else {
            let displayID: CGDirectDisplayID = { if case .display(let id) = target { return id }; return CGMainDisplayID() }()
            if let mode = CGDisplayCopyDisplayMode(displayID) {
                w = CGFloat(mode.pixelWidth); h = CGFloat(mode.pixelHeight)
            }
        }
        guard w > 0, h > 0 else { return (1920, 1080) }
        let factor = min(1, CGFloat(quality.maxLongEdge) / max(w, h))
        func even(_ v: CGFloat) -> Int { let i = max(2, min(5120, Int(v.rounded()))); return i - i % 2 }
        return (even(w * factor), even(h * factor))
    }

    // MARK: Target listing for the Settings picker

    static func availableTargets() async -> [ScreenTargetOption] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return [ScreenTargetOption(id: "main", label: "Main Display", target: .mainDisplay)]
        }
        let ownBundle = Bundle.main.bundleIdentifier
        var options: [ScreenTargetOption] = [
            ScreenTargetOption(id: "main", label: "Main Display", target: .mainDisplay)
        ]
        for (i, d) in content.displays.enumerated() {
            options.append(ScreenTargetOption(
                id: "display:\(d.displayID)",
                label: "Display \(i + 1) — \(Int(d.frame.width))×\(Int(d.frame.height))",
                target: .display(d.displayID)))
        }
        for w in content.windows where (w.title?.isEmpty == false) && w.frame.width > 120 && w.frame.height > 80 {
            guard w.owningApplication?.bundleIdentifier != ownBundle else { continue }
            let app = w.owningApplication?.applicationName ?? "App"
            options.append(ScreenTargetOption(
                id: "window:\(w.windowID)",
                label: "🪟 \(app) — \(w.title ?? "")",
                target: .window(w.windowID)))
        }
        let appsWithWindows = Set(content.windows.compactMap { $0.owningApplication?.bundleIdentifier })
        for a in content.applications
        where appsWithWindows.contains(a.bundleIdentifier) && a.bundleIdentifier != ownBundle {
            options.append(ScreenTargetOption(
                id: "app:\(a.bundleIdentifier)",
                label: "📱 \(a.applicationName) — all windows",
                target: .app(a.bundleIdentifier)))
        }
        return options
    }
}

// MARK: - ScreenWriter (the encoder — no ScreenCaptureKit, so it self-tests headlessly)

/// H.264 video + AAC audio into one `.mp4`, both stamped on the caller's timeline.
///
/// Deliberately free of ScreenCaptureKit and of any UI: it takes pixel buffers and Float samples,
/// which is exactly what `--selftest-screenrec` can synthesize with no permissions and no screen.
final class ScreenWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioFormat: CMAudioFormatDescription?

    private var started = false
    private var finished = false
    private var lastVideoPTS: TimeInterval = -1
    private var audioSamplesWritten: Int64 = 0
    private(set) var frameCount = 0
    let width: Int
    let height: Int

    /// 16 kHz mono — the canonical format every capture path in this app already resamples to.
    static let audioSampleRate: Double = 16_000

    init(url: URL, width: Int, height: Int, quality: ScreenQuality) throws {
        self.width = width
        self.height = height
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.bitrate(width: width, height: height),
                AVVideoMaxKeyFrameIntervalKey: Int(quality.fps) * 4,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.audioSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.audioSampleRate,
                                    channels: 1, interleaved: false)?.formatDescription
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings,
                                        sourceFormatHint: audioFormat)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw ClipExportError.writeFailed("asset writer rejected the inputs")
        }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw ClipExportError.writeFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        started = true
    }

    // MARK: Append

    /// Append one captured frame at session time `t` (seconds). Frames that arrive out of order, or
    /// while the encoder is saturated, are dropped rather than queued — dropping a frame costs a
    /// slightly longer hold on screen; blocking would stall the capture thread the audio shares.
    ///
    /// The FIRST frame is the exception, twice over: it waits briefly for the encoder to come up, and
    /// it is stamped at zero regardless of when it actually arrived. ScreenCaptureKit takes a moment
    /// to deliver anything, and a video whose first sample sits at 0.4 s opens on black — so the
    /// opening frame is held from the start of the timeline instead.
    func appendVideo(_ pixels: CVPixelBuffer, at t: TimeInterval) {
        guard started, !finished else { return }
        let isFirst = frameCount == 0
        if !videoInput.isReadyForMoreMediaData {
            guard isFirst else { return }
            var waited = 0
            while !videoInput.isReadyForMoreMediaData, waited < 20 { usleep(5_000); waited += 1 }
            guard videoInput.isReadyForMoreMediaData else { return }
        }
        let time = isFirst ? 0 : t
        guard isFirst || time > lastVideoPTS else { return }
        if adaptor.append(pixels, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) {
            lastVideoPTS = time
            frameCount += 1
        }
    }

    /// Append the session's audio. PTS comes from the running sample count, so the audio track is
    /// exactly as long as the audio the transcript was made from — pauses drop samples upstream (the
    /// `CaptureGate`), which shortens both identically.
    func appendAudio(_ samples: [Float]) {
        guard started, !finished, let audioFormat, audioInput.isReadyForMoreMediaData else { return }
        let pts = CMTime(value: audioSamplesWritten, timescale: CMTimeScale(Self.audioSampleRate))
        guard let buffer = Self.makeAudioSampleBuffer(samples, format: audioFormat, pts: pts) else { return }
        if audioInput.append(buffer) { audioSamplesWritten += Int64(samples.count) }
    }

    /// Finalize. `endingAt` is the session's true length: ScreenCaptureKit sends nothing while the
    /// screen is static, so without this a recording that ends on a still frame would be shorter
    /// than its own transcript.
    func finish(endingAt endTime: TimeInterval) async -> ScreenRecordingResult? {
        guard started, !finished else { return nil }
        finished = true
        videoInput.markAsFinished()
        audioInput.markAsFinished()

        let audioEnd = Double(audioSamplesWritten) / Self.audioSampleRate
        let end = max(max(endTime, audioEnd), max(0, lastVideoPTS))
        writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 600))
        await writer.finishWriting()

        guard writer.status == .completed else {
            NSLog("[ScreenRec] write failed: \(writer.error?.localizedDescription ?? "unknown")")
            return nil
        }
        guard frameCount > 0 else {
            // Nothing was ever drawn (the target was closed immediately) — leave no stub file behind.
            try? FileManager.default.removeItem(at: writer.outputURL)
            return nil
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: writer.outputURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ScreenRecordingResult(url: writer.outputURL, duration: end, byteSize: size,
                                     width: width, height: height, frameCount: frameCount)
    }

    // MARK: PCM → CMSampleBuffer

    static func makeAudioSampleBuffer(_ samples: [Float], format: CMAudioFormatDescription,
                                      pts: CMTime) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Float>.size
        guard byteCount > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                                 flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                 offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(audioSampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = MemoryLayout<Float>.size
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: format, sampleCount: samples.count,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
}
