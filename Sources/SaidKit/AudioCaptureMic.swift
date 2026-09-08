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
public final class AudioCaptureMic: @unchecked Sendable {
    public init() {}

    private let control = DispatchQueue(label: "com.nikhil.transcriber.mic.control")

    private var engine: AVAudioEngine?
    private var running = false
    private var sink: (any SampleReceiver)?
    private var configObserver: NSObjectProtocol?
    #if os(macOS)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    #else
    private var routeObserver: NSObjectProtocol?
    #endif
    private var restartScheduled = false

    /// Fired (main thread) after the capture successfully rebuilt around a new input device.
    public var onRestart: ((String) -> Void)?
    /// Fired (main thread) when the capture could not be rebuilt after repeated attempts.
    public var onFailure: ((String) -> Void)?

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
    public func start(sink: any SampleReceiver) async throws {
        guard await requestPermission() else { throw CaptureError.micDenied }
        try control.sync {
            guard !running else { return }
            self.sink = sink
            try startEngine(sink: sink)
            running = true
            installObservers()
        }
    }

    public func stop() {
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
    public func forceRestart(reason: String) {
        control.async { [weak self] in self?.restart(reason: reason) }
    }

    // MARK: - Engine (always on `control`)

    private func startEngine(sink: any SampleReceiver) throws {
        // PHASE 3 (iOS): the audio session is configured and activated HERE, not in `start(sink:)`.
        //
        // `startEngine` has two callers — `start(sink:)` and `restart(reason:)`. If activation lived
        // only in `start`, then every device-change rebuild and every `forceRestart` would run
        // against a possibly-deactivated session, `inputFormat` would come back at 0 Hz, and the
        // guard below would throw `CaptureError.micDenied` — whose message sends the user to the
        // microphone privacy settings for what is actually a session-activation bug.
        #if !os(macOS)
        try configureAudioSessionForRecording()
        #endif

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

    #if !os(macOS)
    /// Category `.record`, mode `.default`, plus Bluetooth when the user has opted in.
    ///
    /// Bluetooth is OFF by default and is a deliberate choice, not an oversight: routing the mic
    /// over HFP drops it to a narrowband mono link that is audibly worse than the built-in mic.
    /// The UI states that cost where the toggle lives.
    public static var allowsBluetoothInput = false

    private func configureAudioSessionForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = []
        if Self.allowsBluetoothInput { options.insert(.allowBluetooth) }
        try session.setCategory(.record, mode: .default, options: options)
        try session.setActive(true)
    }

    /// Hand the session back, letting whatever was playing before resume.
    public func deactivateAudioSession() {
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { NSLog("[Mic] session deactivate failed: \(error)") }
    }
    #endif

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
        // in a headset"), and it does not always come with a usable configuration-change.
        //
        // PLATFORM SEAM (C6). Both branches are the same contract — "tell me when the input route
        // changed so I can rebuild around it" — expressed in each platform's own vocabulary:
        //   macOS: a CoreAudio listener on kAudioHardwarePropertyDefaultInputDevice.
        //   iOS:   AVAudioSession.routeChangeNotification, which is what fires when the user plugs
        //          in headphones, connects AirPods, or the OS reroutes for a call.
        #if os(macOS)
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
        #else
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] note in
            // REASON FILTERING IS LOAD-BEARING. `setActive(true)` itself posts a route change with
            // reason `.categoryChange`; rebuilding on every notification would make activation
            // trigger a rebuild, which re-activates, which posts again — a loop. Only an actual
            // change of available hardware justifies rebuilding the engine.
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable:
                self?.control.async { self?.scheduleRestart(reason: "input device changed") }
            default:
                break   // .categoryChange / .override / .wakeFromSleep / .routeConfigurationChange
            }
        }
        #endif
    }

    private func removeObservers() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        #if os(macOS)
        if let deviceListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, deviceListener)
            self.deviceListener = nil
        }
        #else
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        #endif
    }
}
