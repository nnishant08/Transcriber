import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

/// System-audio capture via ScreenCaptureKit — the FALLBACK backend (the Core Audio process tap is
/// the default; see AudioCaptureProcessTap). Audio-only: a tiny 2×2 video track exists purely to
/// satisfy the audio API. Screen recording runs its own separate video stream, so this path never
/// carries video and its verified audio config is untouched.
final class AudioCaptureSystem: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let resampler = Resampler16k()
    private let audioQueue = DispatchQueue(label: "com.nikhil.transcriber.sck.audio")
    private weak var sink: (any SampleReceiver)?
    private var stopping = false

    /// Fired if the stream stops unexpectedly (e.g. display disconnect). AppModel recovers the
    /// capture in place rather than ending the session.
    var onStreamStopped: (() -> Void)?

    func start(sink: any SampleReceiver) async throws {
        self.sink = sink
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

        // Audio-only path — DO NOT change (verified).
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        self.stream = stream

        try await stream.startCapture()
        NSLog("[SystemAudio] capture started")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        stopping = true
        try? stream.removeStreamOutput(self, type: .audio)
        do { try await stream.stopCapture() } catch { NSLog("[SystemAudio] stop error: \(error)") }
        NSLog("[SystemAudio] stopped")
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let sink else { return }
        guard let pcm = sampleBuffer.asPCMBuffer, pcm.frameLength > 0 else { return }
        if let samples = resampler.resample(pcm) { sink.append(samples) }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[SystemAudio] stream stopped with error: \(error)")
        guard !stopping else { return }
        DispatchQueue.main.async { [weak self] in self?.onStreamStopped?() }
    }
}
