import SaidKit
import Foundation
import AVFoundation
import CoreAudio
import QuartzCore

/// System-audio capture via a **Core Audio process tap** (macOS 14.2+).
///
/// This is the device- and screen-independent path. Unlike `AudioCaptureSystem` — which rides
/// ScreenCaptureKit and therefore only hears processes that own a window on the captured display
/// (a windowless process such as `afplay` is captured as pure digital silence) — a process tap
/// attaches to the audio engine itself:
///
///   * every process's output is included, window or not, foreground or not;
///   * it is independent of the output device — built-in speakers, external, headphones, AirPods,
///     or nothing plugged in at all;
///   * it is upstream of the device's volume and mute, and `muteBehavior = .unmuted` guarantees
///     tapping never changes what the user hears.
///
/// Mechanically: create a global tap excluding our own process, then wrap it in a private
/// aggregate device so an IOProc can pull the tapped mix. Samples are resampled to 16 kHz mono
/// and pushed into the same `SampleReceiver` the other captures use, so everything downstream
/// (streamer, finalPass, mixer, diarization) is untouched.
///
/// The tap API landed in macOS 14.2, two minor versions above the deployment target, so every
/// entry point is `#available`-gated and falls back to `AudioCaptureSystem`.
@available(macOS 14.2, *)
final class AudioCaptureProcessTap {

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var tapUUID: String?

    private let resampler = Resampler16k()
    private let ioQueue = DispatchQueue(label: "com.nikhil.transcriber.tap.io")
    private weak var sink: (any SampleReceiver)?

    /// Everything below is confined to `ioQueue` (the IOProc block, the property listeners, and the
    /// watchdog timer all run there).
    private var running = false
    /// When a callback last arrived (the stream is alive).
    private var lastIOAt: TimeInterval = 0
    /// When a callback last carried actual signal — nonzero audio. Distinct from `lastIOAt`: a tap
    /// that has stopped hearing the engine keeps calling us with zero-filled buffers forever.
    private var lastSamplesAt: TimeInterval = 0
    private var zeroRestarts = 0
    private var lastZeroRestartAt: TimeInterval = 0
    private var builtWithOutputUID: String?
    private var watchdog: DispatchSourceTimer?
    private var rebuilding = false

    /// Fired if the tap stops unexpectedly. Mirrors `AudioCaptureSystem.onStreamStopped` so
    /// AppModel can recover (or finalize) the same way regardless of which backend is running.
    var onStreamStopped: (() -> Void)?
    /// Fired (main thread) after the tap successfully rebuilt itself around a device change.
    var onRestart: ((String) -> Void)?

    // MARK: - Lifecycle

    func start(sink: any SampleReceiver) throws {
        self.sink = sink
        try ioQueue.sync {
            try buildChain()
            running = true
        }
        installDeviceChangeListener()
        startWatchdog()
    }

    func stop() {
        ioQueue.sync { running = false }
        stopWatchdog()
        // Drop the listeners from OUTSIDE ioQueue — removing a Core Audio property listener while
        // standing on the queue it was registered with is a deadlock waiting to happen.
        removeDeviceChangeListener()
        ioQueue.sync {
            stopIO()
            teardown()
        }
        NSLog("[ProcessTap] stopped")
    }

    /// Build the whole capture chain: tap → format → private aggregate → IOProc → start.
    /// Always on `ioQueue`, and always in full — a restart re-creates the TAP as well as the
    /// aggregate. That matters: the tap is created while one device is default, and re-reading its
    /// format (and remaking it outright) is the only way to be sure a device change can't leave us
    /// with a live-but-silent stream. Rebuilding just the aggregate is not enough.
    private func buildChain() throws {
        let description = try Self.makeTapDescription()
        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
            throw CaptureError.processTapUnavailable(tapStatus)
        }
        tapID = newTap
        tapUUID = description.uuid.uuidString

        // The tap's own stream format drives the resampler; it is whatever the engine mixes at.
        // Re-read on EVERY build — a stale format silently turns every buffer into a dropped one.
        guard let format = Self.streamFormat(of: tapID) else {
            teardown()
            throw CaptureError.processTapUnavailable(noErr)
        }
        tapFormat = format

        do {
            let outputUID = Self.defaultOutputDeviceUID()
            aggregateID = try Self.makeAggregateDevice(tapUUID: description.uuid.uuidString, outputUID: outputUID)
            builtWithOutputUID = outputUID
        } catch {
            teardown()
            throw error
        }

        // The IOProc receives the tapped mix as INPUT; there is no output to render.
        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
        guard procStatus == noErr, let newProc else {
            teardown()
            throw CaptureError.processTapUnavailable(procStatus)
        }
        procID = newProc

        let startStatus = AudioDeviceStart(aggregateID, newProc)
        guard startStatus == noErr else {
            teardown()
            throw CaptureError.processTapUnavailable(startStatus)
        }
        lastIOAt = CACurrentMediaTime()
        lastSamplesAt = lastIOAt
        NSLog("[ProcessTap] capture chain built (format=\(format.sampleRate)Hz \(format.channelCount)ch, "
              + "output=\(builtWithOutputUID ?? "none"))")
    }

    private func stopIO() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
        }
    }

    // MARK: - Surviving an output-device change

    /// The aggregate device clocks off whichever output device was default when it was built, so
    /// plugging in headphones, docking a monitor, or switching to an external speaker mid-recording
    /// would otherwise stall the IOProc. Rebuild the aggregate (the tap itself is global and
    /// unaffected) so capture continues across the switch — including the case where the old device
    /// disappears entirely, and the case where there is no output device at all.
    ///
    /// Three independent triggers, because no single one catches every real-world switch:
    ///   * the DEFAULT OUTPUT device changing (AirPods connect, monitor speakers selected);
    ///   * the DEVICE LIST changing while our clock device's UID is no longer the default
    ///     (unplugging the device the aggregate was built around);
    ///   * the watchdog — no IO callbacks for a few seconds, whatever the cause.
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func installDeviceChangeListener() {
        let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.ioQueue.async { self?.restartCapture(reason: "output device changed") }
        }
        defaultOutputListener = outputBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &Self.defaultOutputAddress, ioQueue, outputBlock)

        // A device appearing/disappearing only matters when it moved the clock device out from
        // under us; otherwise leave a working capture alone.
        let listBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.ioQueue.async {
                guard let self, self.running else { return }
                let current = Self.defaultOutputDeviceUID()
                guard current != self.builtWithOutputUID else { return }
                self.restartCapture(reason: "audio device list changed")
            }
        }
        deviceListListener = listBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &Self.deviceListAddress, ioQueue, listBlock)
    }

    private func removeDeviceChangeListener() {
        if let defaultOutputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &Self.defaultOutputAddress, ioQueue, defaultOutputListener)
            self.defaultOutputListener = nil
        }
        if let deviceListListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &Self.deviceListAddress, ioQueue, deviceListListener)
            self.deviceListListener = nil
        }
    }

    /// Tear the whole chain down and stand it back up around the CURRENT default device, so capture
    /// continues across a switch — including the case where the old device disappears entirely, and
    /// the case where there is no output device at all.
    ///
    /// Retries with a short backoff: a device transition can leave Core Audio momentarily unable to
    /// create a tap or an aggregate, and giving up on the first failure is what ends a session
    /// unnecessarily.
    private func restartCapture(reason: String, attempt: Int = 0) {
        guard running else { return }
        // One restart at a time: the watchdog keeps ticking while a retry chain is in flight.
        if attempt == 0 {
            guard !rebuilding else { return }
            rebuilding = true
        }
        stopIO()
        teardown()
        do {
            try buildChain()
            rebuilding = false
            NSLog("[ProcessTap] \(reason) — capture chain rebuilt, recording continues")
            DispatchQueue.main.async { [weak self] in self?.onRestart?(reason) }
        } catch {
            guard attempt < 8 else {
                rebuilding = false
                NSLog("[ProcessTap] could not rebuild after \(reason): \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in self?.onStreamStopped?() }
                return
            }
            ioQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restartCapture(reason: reason, attempt: attempt + 1)
            }
        }
    }

    // MARK: - Watchdog

    /// Two distinct failures, two signals — a tap can break in either of these ways, and the second
    /// one is invisible to a callback-based watchdog:
    ///
    /// 1. **Callbacks stop.** The aggregate died. `lastIOAt` goes stale.
    /// 2. **Callbacks keep arriving carrying nothing.** The stream is alive but no longer hears the
    ///    audio engine — what a device change can leave behind. Callbacks look healthy, so only the
    ///    absence of usable SAMPLES reveals it (`lastSamplesAt`).
    ///
    /// Case 2 is deliberately given a much longer fuse than case 1 (and is bounded by
    /// `zeroRestarts`), because genuinely silent playback produces exactly the same zeros. A few
    /// cheap restarts are worth it; an endless restart loop through a quiet meeting is not.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + 2, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.running, !self.rebuilding else { return }
            let now = CACurrentMediaTime()
            if now - self.lastIOAt >= AudioActivity.stallSeconds {
                self.restartCapture(reason: "capture stalled (no callbacks)")
                return
            }
            guard self.zeroRestarts < 3,
                  now - self.lastSamplesAt >= Self.silentRestartSeconds,
                  now - self.lastZeroRestartAt >= Self.silentRestartSeconds else { return }
            self.zeroRestarts += 1
            self.lastZeroRestartAt = now
            self.lastSamplesAt = now
            self.restartCapture(reason: "stream alive but silent for \(Int(Self.silentRestartSeconds))s")
        }
        timer.resume()
        watchdog = timer
    }

    /// How long an alive-but-silent stream is tolerated before the chain is rebuilt once.
    private static let silentRestartSeconds: TimeInterval = 12

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func teardown() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapFormat = nil
    }

    // MARK: - Audio delivery

    private func handle(_ bufferList: UnsafePointer<AudioBufferList>) {
        // Runs on ioQueue — the same queue every other mutation of this state uses.
        let now = CACurrentMediaTime()
        lastIOAt = now
        guard let sink, let tapFormat else { return }
        // A nil buffer here means the tap's format no longer describes what it is handing us (a
        // device change can do that), which would otherwise drop every buffer in silence.
        guard let pcm = AVAudioPCMBuffer(pcmFormat: tapFormat,
                                         bufferListNoCopy: bufferList,
                                         deallocator: nil),
              pcm.frameLength > 0 else { return }
        guard let samples = resampler.resample(pcm) else { return }
        sink.append(samples)
        // Only real signal counts as "this tap is working" — see the watchdog.
        if samples.contains(where: { $0 != 0 }) {
            lastSamplesAt = now
            zeroRestarts = 0
        }
    }

    // MARK: - Tap construction

    /// A stereo mixdown of every process EXCEPT our own (the same intent as
    /// `SCStreamConfiguration.excludesCurrentProcessAudio`, so playback inside Transcriber — e.g.
    /// the Session Viewer's player — is never fed back into a live recording).
    private static func makeTapDescription() throws -> CATapDescription {
        let description: CATapDescription
        if let own = processObject(for: getpid()) {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [own])
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.name = "Said System Audio"
        description.uuid = UUID()
        description.isPrivate = true          // visible only to us; never appears as a user device
        description.muteBehavior = .unmuted   // tapping must not change what the user hears
        return description
    }

    /// The Core Audio process object for a pid, used to exclude ourselves from the global tap.
    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pidValue,
                                                &size, &objectID)
        return status == noErr && objectID != kAudioObjectUnknown ? objectID : nil
    }

    private static func streamFormat(of tap: AudioObjectID) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// A private aggregate device wrapping the tap. The current default output device is used as
    /// the clock source when one exists; when it does not (nothing plugged in / no output device),
    /// the tap still aggregates on its own — capture must not depend on an output existing.
    private static func makeAggregateDevice(tapUUID: String, outputUID: String?) throws -> AudioObjectID {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Said Capture",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: tapUUID,
                kAudioSubTapDriftCompensationKey as String: true,
            ]],
        ]
        if let outputUID {
            description[kAudioAggregateDeviceMainSubDeviceKey as String] = outputUID
            description[kAudioAggregateDeviceSubDeviceListKey as String] = [[
                kAudioSubDeviceUIDKey as String: outputUID,
            ]]
        }

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            throw CaptureError.processTapUnavailable(status)
        }
        return aggregate
    }

    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                         &size, &deviceID) == noErr, deviceID != 0 else { return nil }

        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid) == noErr,
              let value = uid?.takeRetainedValue() else { return nil }
        return value as String
    }
}
