import XCTest
import AVFoundation
import SaidKit

/// The interruption paths, driven as STATE MACHINE transitions rather than through `AVAudioSession`.
///
/// These assert the exact call sequences `RecordingModel+Interruptions` performs, against the same
/// `CaptureControl` primitives the Mac's `--selftest-pause` covers. Testing the notifications
/// themselves would test AVFoundation; testing these catches the bugs that actually bite.
final class CaptureStateMachineTests: XCTestCase {

    /// Collects whatever reaches the sink, so "did audio leak through" is directly observable.
    private final class Collector: SampleReceiver, @unchecked Sendable {
        private(set) var received: [Float] = []
        func append(_ samples: [Float]) { received.append(contentsOf: samples) }
    }

    private func speech(_ n: Int = 1_600, level: Float = 0.08) -> [Float] {
        (0..<n).map { _ in Float.random(in: -level...level) }
    }

    // MARK: Interruption began

    func testInterruptionBeganClosesGateAndPausesClock() {
        let out = Collector()
        let gate = CaptureGate(downstream: out)
        var clock = SessionClock(t0: 0)

        gate.append(speech())
        XCTAssertEqual(out.received.count, 1_600, "audio flows before the interruption")

        // handleInterruptionBegan()
        clock.pause(now: 10)
        gate.close()

        gate.append(speech())
        XCTAssertEqual(out.received.count, 1_600,
                       "audio captured DURING an interruption must never reach the session")
        XCTAssertEqual(clock.time(now: 20), 10, accuracy: 0.001,
                       "the interrupted stretch is absent from the timeline")
    }

    // MARK: Interruption ended, with .shouldResume

    func testInterruptionResumeDiscardsPreRoll() {
        let out = Collector()
        let gate = CaptureGate(downstream: out)

        gate.close()
        gate.append(speech())          // retained as pre-roll while closed
        let beforeResume = out.received.count

        // handleInterruptionEnded(shouldResume: true) → resume() with replay == false, because
        // pauseKind is .interruption, not .silence.
        gate.open(flushPreroll: false)

        XCTAssertEqual(out.received.count, beforeResume,
                       "pre-roll captured during the user's phone call must NOT be replayed")
    }

    /// The counter-case: an automatic (silence) resume DOES replay, so the word that woke it isn't clipped.
    func testSilenceResumeReplaysPreRoll() {
        let out = Collector()
        let gate = CaptureGate(downstream: out)

        gate.close()
        gate.append(speech())
        XCTAssertEqual(out.received.count, 0)

        gate.open(flushPreroll: true)
        XCTAssertGreaterThan(out.received.count, 0,
                             "an automatic resume replays pre-roll so the first word survives")
    }

    // MARK: The trap — an interruption must never be recorded as .silence

    func testInterruptionPauseMustNotAutoResume() {
        var monitor = SilenceMonitor(enabled: true, pauseAfter: 30)

        // A phone call arrives mid-sentence, so the gate's frozen level is LOUD. `CaptureGate.level`
        // is written only in `append` and is never zeroed by `close()`, so it keeps reporting that
        // loud value for the whole interruption.
        let loudFrozenLevel: Float = 0.09

        // Recorded correctly, as .manual:
        for t in stride(from: 0.0, through: 5.0, by: 0.25) {
            let decision = monitor.update(level: loudFrozenLevel, now: t, paused: true, reason: .manual)
            XCTAssertNotEqual(decision, .autoResume,
                              "a manual/interruption pause must never resume itself")
        }
    }

    /// And the reason that matters: labelled `.silence`, the same frozen level DOES auto-resume —
    /// which would un-pause the session in the middle of the call.
    func testSilenceLabelWouldAutoResumeOnAFrozenLevel() {
        var monitor = SilenceMonitor(enabled: true, pauseAfter: 30)
        var resumed = false
        for t in stride(from: 0.0, through: 5.0, by: 0.25) {
            if monitor.update(level: 0.09, now: t, paused: true, reason: .silence) == .autoResume {
                resumed = true; break
            }
        }
        XCTAssertTrue(resumed, "documents WHY .silence is the wrong label for an interruption")
    }

    // MARK: Route lost

    func testRouteLostPausesRatherThanSwitchingMics() {
        let out = Collector()
        let gate = CaptureGate(downstream: out)
        var clock = SessionClock(t0: 0)

        gate.append(speech())
        let before = out.received.count

        // handleRouteLost() — headphones pulled.
        clock.pause(now: 5)
        gate.close()
        gate.append(speech())

        XCTAssertEqual(out.received.count, before,
                       "pulling headphones pauses; it does not silently continue on another mic")
    }

    // MARK: The watchdog must not fight an interruption

    func testStallMonitorWouldFireDuringAnInterruption() {
        var stall = StallMonitor()
        stall.start(now: 0)
        // During an iOS interruption the engine is stopped, so lastDelivery freezes.
        let frozen: TimeInterval = 0
        XCTAssertTrue(stall.shouldRecover(lastDelivery: frozen, now: 10),
                      "documents why updateCaptureHealth needs a !isPaused guard on iOS")
    }

    // MARK: Timeline integrity across a pause

    func testTimestampsStayOnTheCompressedClock() {
        var clock = SessionClock(t0: 100)
        XCTAssertEqual(clock.time(now: 110), 10, accuracy: 0.001)

        clock.pause(now: 110)
        clock.resume(now: 170)                    // a 60-second phone call
        XCTAssertEqual(clock.time(now: 180), 20, accuracy: 0.001,
                       "paused time is absent, so a bookmark after the call matches the audio")
        XCTAssertEqual(clock.totalPaused(now: 180), 60, accuracy: 0.001)
    }
}
