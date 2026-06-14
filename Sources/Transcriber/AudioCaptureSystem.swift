import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

/// System-audio capture via ScreenCaptureKit. When `visual` is nil this is exactly the original,
/// user-verified audio-only path (a tiny 2×2 video track present only to satisfy the audio API).
/// When `visual` is provided, the SAME single stream also carries real video frames: `.audio` →
/// the shared `SampleSink` (unchanged), `.screen` → the VisualCapture detector. One stream, one
/// Screen Recording grant, no audio regression.
final class AudioCaptureSystem: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let resampler = Resampler16k()
    private let audioQueue = DispatchQueue(label: "com.nikhil.transcriber.sck.audio")
    private weak var sink: (any SampleReceiver)?
    private weak var visual: VisualCapture?
    private var stopping = false

    /// Fired if the stream stops unexpectedly (e.g. display disconnect, or a captured window
    /// closing in the shared-stream case). AppModel uses it to finalize the session gracefully.
    var onStreamStopped: (() -> Void)?

    func start(sink: any SampleReceiver, visual: VisualCapture? = nil) async throws {
        self.sink = sink
        self.visual = visual
        self.stopping = false

        // Enumerating shareable content is the authoritative authorization test + the TCC trigger.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            NSLog("[SystemAudio] shareable content failed — Screen Recording likely not granted: \(error)")
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            throw CaptureError.screenRecordingNeedsGrant
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter: SCContentFilter
        let config = SCStreamConfiguration()

        if let visual {
            // Shared audio+video stream scoped to the chosen visual target.
            filter = try visual.makeFilter(content: content)
            let videoConfig = visual.makeVideoConfig(content: content, withAudio: true)
            // Copy video+audio settings from the visual config.
            config.width = videoConfig.width
            config.height = videoConfig.height
            config.minimumFrameInterval = videoConfig.minimumFrameInterval
            config.showsCursor = videoConfig.showsCursor
            config.scalesToFit = videoConfig.scalesToFit
            config.pixelFormat = videoConfig.pixelFormat
            config.queueDepth = videoConfig.queueDepth
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        } else {
            // Original audio-only path — DO NOT change (verified).
            filter = SCContentFilter(display: display, excludingWindows: [])
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 6
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        if let visual {
            // Deliver screen frames straight onto VisualCapture's serial queue.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: visual.sampleHandlerQueue)
        }
        self.stream = stream

        try await stream.startCapture()
        NSLog("[SystemAudio] capture started (visual=\(visual != nil))")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        stopping = true
        try? stream.removeStreamOutput(self, type: .audio)
        try? stream.removeStreamOutput(self, type: .screen)   // no-op (throws, swallowed) if not added
        do { try await stream.stopCapture() } catch { NSLog("[SystemAudio] stop error: \(error)") }
        NSLog("[SystemAudio] stopped")
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            guard sampleBuffer.isValid, let sink else { return }
            guard let pcm = sampleBuffer.asPCMBuffer, pcm.frameLength > 0 else { return }
            if let samples = resampler.resample(pcm) { sink.append(samples) }
        case .screen:
            visual?.ingest(sampleBuffer)
        default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[SystemAudio] stream stopped with error: \(error)")
        guard !stopping else { return }
        DispatchQueue.main.async { [weak self] in self?.onStreamStopped?() }
    }
}
