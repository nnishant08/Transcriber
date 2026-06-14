import Foundation
import AVFoundation

/// Microphone capture via AVAudioEngine. Installs a tap on the input node, resamples
/// each buffer to 16 kHz mono Float32, and pushes the samples into the shared sink.
final class AudioCaptureMic {
    private let engine = AVAudioEngine()
    private let resampler = Resampler16k()
    private var running = false

    /// Requests microphone permission (triggers the NSMicrophoneUsageDescription prompt
    /// on first use). Returns true if authorized.
    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// `sink` is a `SampleReceiver`: the shared `SampleSink` for single-source recording (byte-identical
    /// to before), or an `AudioMixer.Port` for the Mic+System mode.
    func start(sink: any SampleReceiver) async throws {
        guard await requestPermission() else { throw CaptureError.micDenied }
        guard !running else { return }

        let input = engine.inputNode
        // Tap in the hardware's native input format; the resampler handles conversion.
        let format = input.inputFormat(forBus: 0)
        // Guard the no-input-device case (format would be 0 Hz / 0 channels → installTap crashes).
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.micDenied
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if let samples = self.resampler.resample(buffer) {
                sink.append(samples)
            }
        }

        engine.prepare()
        try engine.start()
        running = true
        NSLog("[Mic] started, input format: \(format)")
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        NSLog("[Mic] stopped")
    }
}
