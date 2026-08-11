import Foundation
import QuartzCore

/// Pause / auto-pause / capture-health primitives.
///
/// Everything here is deliberately small and PURE (or single-purpose and lock-guarded) so the
/// decisions that govern a live recording — "is this silence?", "should we resume?", "has the
/// capture died?", "what time is it in the recorded timeline?" — can be self-tested headlessly
/// (`--selftest-pause`) instead of only being observable during a real session.
///
/// Non-regression note: `CaptureGate` sits between a capture source and the sink/mixer. While it
/// is OPEN it forwards the exact array it was handed, so an unpaused recording is byte-identical
/// to one with no gate at all.

// MARK: - Tunables

enum AudioActivity {
    /// RMS below this counts as "no audio". A live mic's room tone sits around 0.001–0.003 and
    /// speech around 0.02–0.15, so this floor separates "nobody is talking / nothing is playing"
    /// from real signal without firing on a quiet room. Digital silence (exact zeros) is 0.
    static let silenceRMS: Float = 0.004
    /// Default idle time before an automatic pause.
    static let defaultAutoPauseSeconds: TimeInterval = 30
    /// Sound must persist this long before an auto-pause resumes itself (ignores a single click/pop).
    static let resumeSoundSeconds: TimeInterval = 0.2
    /// Audio retained while paused and replayed on resume, so the first word back isn't clipped.
    static let prerollSeconds: Double = 1.0
    /// No sample buffers at all for this long ⇒ the capture is dead, not quiet (a live capture keeps
    /// delivering buffers even when they are zero-filled).
    static let stallSeconds: TimeInterval = 3.0
    /// Minimum spacing between two recovery attempts for the same source.
    static let recoveryCooldown: TimeInterval = 6.0
}

// MARK: - Capture gate (pause valve + level/liveness probe)

/// Sits between one capture source and its downstream receiver (the shared `SampleSink`, or an
/// `AudioMixer` port for Mic+System). Two jobs:
///
/// 1. **Pause valve** — while closed, samples are dropped, so paused stretches never enter the
///    recording. The audio timeline stays gapless and `SessionClock` keeps every other timestamp
///    (bookmarks, slides) aligned with it.
/// 2. **Probe** — block RMS and a last-delivery timestamp are recorded on EVERY append, open or
///    closed. That is what makes auto-resume possible (we can still hear that audio came back
///    while paused) and what lets the watchdog tell "silent" from "dead".
final class CaptureGate: SampleReceiver, @unchecked Sendable {
    private let downstream: any SampleReceiver
    private let prerollCapacity: Int
    private let lock = NSLock()

    private var open = true
    private var preroll: [Float] = []
    private var lastRMS: Float = 0
    private var lastDelivery: TimeInterval?

    init(downstream: any SampleReceiver, prerollSeconds: Double = AudioActivity.prerollSeconds) {
        self.downstream = downstream
        self.prerollCapacity = max(0, Int(prerollSeconds * 16_000))
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let level = Self.rms(samples)
        let now = CACurrentMediaTime()
        // Forward INSIDE the lock: a gate has one producer today, but appending outside would
        // allow two callers to reorder PCM at chunk boundaries (the bug already fixed in AudioMixer).
        // Downstream receivers take their own separate locks, so there is no reverse acquisition.
        lock.lock()
        lastRMS = level
        lastDelivery = now
        if open {
            downstream.append(samples)
        } else if prerollCapacity > 0 {
            preroll.append(contentsOf: samples)
            if preroll.count > prerollCapacity { preroll.removeFirst(preroll.count - prerollCapacity) }
        }
        lock.unlock()
    }

    /// Close the valve (pause). Buffered pre-roll from an earlier pause is discarded.
    func close() {
        lock.lock()
        open = false
        preroll.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// Open the valve (resume), flushing the retained pre-roll first so the audio that triggered
    /// an auto-resume — typically the first word of the sentence — is part of the transcript.
    func open(flushPreroll: Bool = true) {
        lock.lock()
        let flush = flushPreroll ? preroll : []
        preroll.removeAll(keepingCapacity: false)
        open = true
        if !flush.isEmpty { downstream.append(flush) }
        lock.unlock()
    }

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    /// RMS of the most recent block — measured even while closed.
    var level: Float { lock.lock(); defer { lock.unlock() }; return lastRMS }
    /// When this gate last received ANY samples (nil = never). Drives the stall watchdog.
    var lastDeliveryAt: TimeInterval? { lock.lock(); defer { lock.unlock() }; return lastDelivery }
    var prerollCount: Int { lock.lock(); defer { lock.unlock() }; return preroll.count }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

// MARK: - Pause state

enum PauseReason: Equatable {
    case manual     // the user pressed Pause (or the hotkey) — only the user resumes it
    case silence    // auto-paused after a silent stretch — resumes itself when audio returns
}

// MARK: - Silence monitor (auto-pause / auto-resume)

enum CaptureDecision: Equatable { case none, autoPause, autoResume }

/// Decides when a recording should auto-pause on silence and auto-resume on sound. Pure: fed a
/// level and a clock, it returns an action. Auto-resume deliberately only un-pauses an AUTOMATIC
/// pause — a manual pause is a decision, and the app must never override it.
struct SilenceMonitor {
    var enabled: Bool = true
    var pauseAfter: TimeInterval = AudioActivity.defaultAutoPauseSeconds
    var resumeAfter: TimeInterval = AudioActivity.resumeSoundSeconds
    var threshold: Float = AudioActivity.silenceRMS

    private var quietSince: TimeInterval?
    private var soundSince: TimeInterval?

    init(enabled: Bool = true, pauseAfter: TimeInterval = AudioActivity.defaultAutoPauseSeconds) {
        self.enabled = enabled
        self.pauseAfter = pauseAfter
    }

    mutating func reset() {
        quietSince = nil
        soundSince = nil
    }

    /// Feed the current input level. `paused`/`reason` describe the state right now.
    mutating func update(level: Float, now: TimeInterval, paused: Bool, reason: PauseReason?) -> CaptureDecision {
        if level >= threshold {
            if soundSince == nil { soundSince = now }
            quietSince = nil
        } else {
            if quietSince == nil { quietSince = now }
            soundSince = nil
        }
        guard enabled else { return .none }

        if paused {
            guard reason == .silence, let since = soundSince, now - since >= resumeAfter else { return .none }
            reset()
            return .autoResume
        }
        guard let since = quietSince, now - since >= pauseAfter else { return .none }
        reset()
        return .autoPause
    }

    /// How long the input has been below the threshold (0 when audio is present).
    func quietSeconds(now: TimeInterval) -> TimeInterval {
        quietSince.map { max(0, now - $0) } ?? 0
    }
}

// MARK: - Stall monitor (capture watchdog)

/// A live capture delivers sample buffers continuously — zero-filled ones when nothing is playing.
/// So "no buffers at all for a few seconds" means the capture itself broke (device switched away,
/// stream torn down by the OS, engine stopped), which is exactly the failure that used to end a
/// session. This decides when to attempt a recovery, with a cooldown so a flapping device can't
/// spin the recovery path.
struct StallMonitor {
    var stallAfter: TimeInterval = AudioActivity.stallSeconds
    var cooldown: TimeInterval = AudioActivity.recoveryCooldown

    private var lastActionAt: TimeInterval?

    /// Arm the monitor at capture start (also the reference point until the first buffer arrives).
    mutating func start(now: TimeInterval) { lastActionAt = now }

    mutating func shouldRecover(lastDelivery: TimeInterval?, now: TimeInterval) -> Bool {
        if let last = lastActionAt, now - last < cooldown { return false }
        let reference = lastDelivery ?? lastActionAt ?? now
        guard now - reference >= stallAfter else { return false }
        lastActionAt = now
        return true
    }
}

// MARK: - Session clock (pause-aware timeline)

/// The session's monotonic clock, with paused stretches removed. Because a pause drops samples
/// rather than padding them, the recorded audio is gapless — so bookmarks, slide frames, and the
/// on-screen timer must all be measured on this compressed timeline to stay aligned with it.
struct SessionClock {
    let t0: TimeInterval
    private(set) var accumulatedPause: TimeInterval = 0
    private(set) var pausedAt: TimeInterval?

    init(t0: TimeInterval) { self.t0 = t0 }

    var isPaused: Bool { pausedAt != nil }

    mutating func pause(now: TimeInterval) { if pausedAt == nil { pausedAt = now } }

    mutating func resume(now: TimeInterval) {
        guard let started = pausedAt else { return }
        accumulatedPause += max(0, now - started)
        pausedAt = nil
    }

    func totalPaused(now: TimeInterval) -> TimeInterval {
        accumulatedPause + (pausedAt.map { max(0, now - $0) } ?? 0)
    }

    /// Seconds of RECORDED time so far — the exact offset of the sink's write head.
    func time(now: TimeInterval) -> TimeInterval {
        max(0, now - t0 - totalPaused(now: now))
    }
}
