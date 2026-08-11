import Foundation
import AVFoundation
import CoreAudio

/// Diagnostic probe for the system-audio capture path (`--selftest-sysaudio [seconds]`).
///
/// Answers one question precisely: **what does ScreenCaptureKit actually hand us as the default
/// output device's mute / volume changes?** It prints, twice a second, the RMS + peak of the
/// samples that landed in the sink alongside the output device's live mute + volume, so a run
/// where you toggle the speaker produces a direct correlation table.
///
/// Motivated by a report of "can't transcribe when the speaker is turned off": SCK's tap sits on
/// the output device, so a hardware/system mute can zero the tap while the app is working fine.
/// This probe is what distinguishes "app broke" from "OS handed us digital silence".
enum SysAudioProbe {

    // MARK: - Output device state (read-only CoreAudio)

    /// The current default output device, or nil if CoreAudio won't report one.
    static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func deviceName(_ id: AudioDeviceID) -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return "?" }
        return value as String
    }

    /// `true` / `false` / nil when the device exposes no mute control.
    static func isMuted(_ id: AudioDeviceID) -> Bool? {
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    /// The device's virtual main output volume, 0…1, or nil when unavailable.
    static func volume(_ id: AudioDeviceID) -> Float? {
        var vol = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &vol) == noErr else { return nil }
        return vol
    }

    private static func outputStateLine() -> String {
        guard let dev = defaultOutputDevice() else { return "output=<none>" }
        let muteText = isMuted(dev).map { $0 ? "MUTED" : "unmuted" } ?? "mute=n/a"
        let volText = volume(dev).map { String(format: "vol=%3.0f%%", $0 * 100) } ?? "vol=n/a"
        return "\(deviceName(dev)) \(muteText) \(volText)"
    }

    // MARK: - Probe

    /// Same probe, but through the Core Audio process tap instead of ScreenCaptureKit. Run both
    /// against the same source to see the difference — a windowless process (`afplay`) reads
    /// 100% zeros on the SCK path and real audio here.
    @available(macOS 14.2, *)
    static func runProcessTap(seconds: Double) {
        let duration = seconds > 0 ? seconds : 20
        print("=== system-audio probe (Core Audio process tap) ===")
        print("Capturing for \(Int(duration))s.\n")
        print("output device: \(outputStateLine())\n")

        let sink = SampleSink()
        let capture = AudioCaptureProcessTap()
        do {
            try capture.start(sink: sink)
        } catch {
            print("FAIL: could not start the process tap: \(error.localizedDescription)")
            exit(1)
        }

        report(sink: sink, duration: duration)
        capture.stop()
        finish(sink: sink)
    }

    static func run(seconds: Double) {
        let duration = seconds > 0 ? seconds : 20
        print("=== system-audio probe ===")
        print("Capturing for \(Int(duration))s. Play audio, then toggle the speaker mute / volume")
        print("and watch whether the captured RMS follows it.\n")
        print("output device: \(outputStateLine())\n")

        let sink = SampleSink()
        let capture = AudioCaptureSystem()
        var failed: Error?

        let started = DispatchSemaphore(value: 0)
        Task {
            do { try await capture.start(sink: sink) } catch { failed = error }
            started.signal()
        }
        started.wait()

        if let failed {
            print("FAIL: could not start system-audio capture: \(failed.localizedDescription)")
            print("(Run this from the signed app bundle so it carries the Screen Recording grant:")
            print("  ./Said.app/Contents/MacOS/Said --selftest-sysaudio)")
            exit(1)
        }

        report(sink: sink, duration: duration)

        let stopped = DispatchSemaphore(value: 0)
        Task { await capture.stop(); stopped.signal() }
        stopped.wait()

        finish(sink: sink)
    }

    // MARK: - Shared reporting (same table for either backend)

    private static var sawAudio = false
    private static var sawExactZeroRun = false

    private static func report(sink: SampleSink, duration: Double) {
        print(" time        rms      peak    zeros  detect  output device")

        var consumed = 0
        sawAudio = false
        sawExactZeroRun = false
        let step = 0.5
        var elapsed = 0.0

        while elapsed < duration {
            Thread.sleep(forTimeInterval: step)
            elapsed += step

            let all = sink.snapshot()
            guard all.count > consumed else {
                print(String(format: "%5.1fs         -         -  no data   %@", elapsed, outputStateLine()))
                continue
            }
            let chunk = Array(all[consumed..<all.count])
            consumed = all.count

            var sumSq: Float = 0
            var peak: Float = 0
            var zeros = 0
            for s in chunk {
                sumSq += s * s
                peak = max(peak, abs(s))
                if s == 0 { zeros += 1 }
            }
            let rms = (sumSq / Float(chunk.count)).squareRoot()
            let zeroPct = Double(zeros) / Double(chunk.count) * 100

            if rms > 0.0005 { sawAudio = true }
            if zeroPct > 99.5 { sawExactZeroRun = true }

            // Also exercise the exact predicate the live "no audio" status-bar warning uses.
            let flagged = sink.recentAllZero() ? "SILENT" : "ok"
            print(String(format: "%5.1fs  %8.5f  %8.5f  %6.1f%%  %-6@  %@",
                         elapsed, rms, peak, zeroPct, flagged as NSString, outputStateLine()))
        }
    }

    /// Set `TRANSCRIBER_PROBE_OUT=/path/out.wav` to dump what the probe captured, so the same
    /// samples can be fed straight to `--selftest` and the capture proven end-to-end.
    private static func dumpIfRequested(_ sink: SampleSink) {
        guard let path = ProcessInfo.processInfo.environment["TRANSCRIBER_PROBE_OUT"] else { return }
        let samples = sink.snapshot()
        guard !samples.isEmpty else { return }
        var data = Data()
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        data.append("RIFF".data(using: .ascii)!); data.append(le32(UInt32(36 + pcm.count)))
        data.append("WAVEfmt ".data(using: .ascii)!); data.append(le32(16))
        data.append(le16(1)); data.append(le16(1))
        data.append(le32(16_000)); data.append(le32(32_000))
        data.append(le16(2)); data.append(le16(16))
        data.append("data".data(using: .ascii)!); data.append(le32(UInt32(pcm.count)))
        data.append(pcm)
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote captured audio → \(path)")
    }

    private static func finish(sink: SampleSink) {
        dumpIfRequested(sink)
        print("\n--- verdict ---")
        print("samples captured: \(sink.count) (\(String(format: "%.1f", Double(sink.count) / 16_000))s @16kHz)")
        if sawAudio && sawExactZeroRun {
            print("MIXED: the capture delivered real audio at times and EXACT digital silence at others.")
            print("→ Correlate the zero runs against the mute/volume columns above.")
        } else if sawExactZeroRun {
            print("SILENT: the capture delivered only zero-filled buffers for this whole run.")
        } else if sawAudio {
            print("OK: the capture delivered real audio throughout.")
        } else {
            print("NO SIGNAL: nothing was playing, or the capture produced no buffers at all.")
        }
        exit(0)
    }
}
