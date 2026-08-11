import Foundation
import AVFoundation
import CoreAudio

/// Microphone capture via AVAudioEngine. Installs a tap on the input node, resamples
/// each buffer to 16 kHz mono Float32, and pushes the samples into the shared sink.
///
/// **Device changes are survivable.** AVAudioEngine binds to the default input device and its
/// format at `start()`; plugging in headphones, docking a monitor, or connecting AirPods swaps
/// that device out from under the engine, which stops delivering (the engine is torn down by the
/// OS and the installed tap is bound to a stale format). Rather than ending the session, the
/// capture rebuilds itself around the NEW device — a fresh engine, a fresh tap in the new input
/// format, a fresh resampler — and keeps pushing into the same `SampleReceiver`, so the streamer,
/// the final pass, and every timestamp downstream are untouched.
final class AudioCaptureMic: @unchecked Sendable {
    private let control = DispatchQueue(label: "com.nikhil.transcriber.mic.control")

    private var engine: AVAudioEngine?
    private var running = false
    private var sink: (any SampleReceiver)?
    private var configObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var restartScheduled = false

    /// Fired (main thread) after the capture successfully rebuilt around a new input device.
    var onRestart: ((String) -> Void)?
    /// Fired (main thread) when the capture could not be rebuilt after repeated attempts.
    var onFailure: ((String) -> Void)?

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
    /// to before), or an `AudioMixer.Port` for the Mic+System mode. In both cases it is wrapped in a
    /// `CaptureGate` by AppModel, which is what pause and the watchdog act on.
    func start(sink: any SampleReceiver) async throws {
        guard await requestPermission() else { throw CaptureError.micDenied }
        try control.sync {
            guard !running else { return }
            self.sink = sink
            try startEngine(sink: sink)
            running = true
            installObservers()
        }
    }

    func stop() {
        // Clear `running` first so any queued restart (a device change racing the stop) becomes a
        // no-op, then drop the listeners from OUTSIDE `control` — removing a Core Audio property
        // listener while standing on the very queue it was registered with is a deadlock waiting to
        // happen. start/stop are both MainActor-serialized, so the observer fields need no lock.
        let wasRunning: Bool = control.sync {
            guard running else { return false }
            running = false
            return true
        }
        guard wasRunning else { return }
        removeObservers()
        control.sync {
            teardownEngine()
            sink = nil
        }
        NSLog("[Mic] stopped")
    }

    /// Force a rebuild around the current default input device (the AppModel watchdog's escape
    /// hatch when the engine goes quiet without posting a configuration-change notification).
    func forceRestart(reason: String) {
        control.async { [weak self] in self?.restart(reason: reason) }
    }

    // MARK: - Engine (always on `control`)

    private func startEngine(sink: any SampleReceiver) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Tap in the hardware's native input format; the resampler handles conversion.
        let format = input.inputFormat(forBus: 0)
        // Guard the no-input-device case (format would be 0 Hz / 0 channels → installTap crashes).
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.micDenied
        }

        // One resampler per engine, captured by the tap: AVAudioConverter keeps resampling state
        // across buffers, and a device switch means a new input format, so the old state must go.
        // Owning it here (rather than as a field) also keeps it off any other thread.
        let resampler = Resampler16k()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let samples = resampler.resample(buffer) { sink.append(samples) }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        NSLog("[Mic] started, input format: \(format)")
    }

    private func teardownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Rebuild around whatever the input device is NOW. Retries with a short backoff because a
    /// device transition (AirPods connecting, a dock waking) can leave Core Audio briefly unable
    /// to hand out a usable input format.
    private func restart(reason: String, attempt: Int = 0) {
        guard running, let sink else { return }
        teardownEngine()
        do {
            try startEngine(sink: sink)
            NSLog("[Mic] rebuilt after \(reason) (attempt \(attempt + 1))")
            let message = reason
            DispatchQueue.main.async { [weak self] in self?.onRestart?(message) }
        } catch {
            guard attempt < 8 else {
                NSLog("[Mic] could not rebuild after \(reason): \(error.localizedDescription)")
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
                return
            }
            control.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restart(reason: reason, attempt: attempt + 1)
            }
        }
    }

    /// Coalesce the burst of notifications a single device switch produces into one rebuild.
    private func scheduleRestart(reason: String) {
        guard running, !restartScheduled else { return }
        restartScheduled = true
        control.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.restartScheduled = false
            self.restart(reason: reason)
        }
    }

    // MARK: - Device-change observers

    private func installObservers() {
        // Posted when the engine's IO configuration changes — the primary signal for a device swap.
        // The engine is already stopped by the time this arrives, so a rebuild is mandatory.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.control.async { self?.scheduleRestart(reason: "audio configuration changed") }
        }

        // Belt and braces: the default INPUT device changing is the user-visible event ("I plugged
        // in a headset"), and it does not always come with a usable configuration-change on macOS.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.control.async { self?.scheduleRestart(reason: "input device changed") }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, block)
    }

    private func removeObservers() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let deviceListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, deviceListener)
            self.deviceListener = nil
        }
    }
}
