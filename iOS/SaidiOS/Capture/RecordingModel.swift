import Foundation
import AVFoundation
import Combine
import SwiftUI
import SaidKit

/// Drives one recording on iPhone.
///
/// This is the iOS counterpart of the Mac's `AppModel` capture half — but it is NOT a second state
/// machine. Every pause, resume, timestamp and watchdog decision routes through the SAME `SaidKit`
/// primitives the Mac uses: `CaptureGate`, `SessionClock`, `SilenceMonitor`, `StallMonitor`. An
/// `AVAudioSession` interruption is an INPUT to that machinery, not a reason to invent a parallel one.
///
/// What is genuinely new here, and only here:
///   • an audio session to negotiate with, and four interruption paths to survive;
///   • a `StreamingAudioWriter`, so a killed app loses nothing.
@MainActor
final class RecordingModel: ObservableObject {

    // MARK: Published state

    enum Status: Equatable {
        case idle
        case preparing(String, Double?)
        case recording
        case paused(PauseKind)
        case finalizing
        case failed(String)
    }

    /// Why we are paused. Distinct from `SaidKit.PauseReason` because the UI copy differs — but it
    /// MAPS onto it deliberately: see `capturePauseReason`.
    enum PauseKind: Equatable { case user, silence, interruption, routeLost }

    @Published private(set) var status: Status = .idle
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var quietSeconds: Int = 0
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var hypothesis: String = ""
    @Published private(set) var bookmarkCount = 0
    @Published private(set) var frameCount = 0
    /// Non-nil while a recovered session is waiting to be acknowledged.
    @Published var recoveredSession: URL?

    var isPaused: Bool { if case .paused = status { return true }; return false }

    // MARK: SaidKit primitives (the same objects the Mac drives)

    private let engine = TranscriptionEngine()
    private let mic = AudioCaptureMic()
    private var gate: CaptureGate?
    private var clock: SessionClock?
    private var silence = SilenceMonitor()
    private var stall = StallMonitor()
    private var writer: StreamingAudioWriter?

    private var streamer: StreamingTranscriber?
    private var streamTask: Task<Void, Never>?
    private var tick: Timer?
    private var busy = false

    // MARK: Session identity

    private var dir: URL?
    private var sessionID = UUID()
    private var startedAt = Date()
    private var t0: TimeInterval = 0
    private var bookmarks: [Bookmark] = []
    private var frames: [FrameEvent] = []
    private var promptTokens: [Int]?
    private var language: String?
    private var pauseKind: PauseKind?
    private var observers: [NSObjectProtocol] = []
    private var thermalObserver: NSObjectProtocol?

    private var settings: SettingsStore { .shared }

    // MARK: - Lifecycle

    init() {
        installInterruptionObservers()
        installPressureObservers()
    }

    /// `PauseReason` has exactly `.manual` and `.silence`. An interruption maps to **`.manual`**, and
    /// that is load-bearing rather than lazy: `CaptureGate.level` freezes at the last measured RMS
    /// (it is written only in `append`, never zeroed by `close()`). Recording an interruption as
    /// `.silence` would let `SilenceMonitor` see a loud frozen level and return `.autoResume` a
    /// fraction of a second later — un-pausing the session in the middle of the user's phone call.
    private var capturePauseReason: PauseReason? {
        switch pauseKind {
        case .silence: return .silence
        case .user, .interruption, .routeLost: return .manual
        case nil: return nil
        }
    }

    // MARK: - Start

    func start() async {
        guard !busy, !isRecording else { return }
        busy = true                                     // synchronously, before any await
        defer { busy = false }

        do {
            status = .preparing("Preparing…", nil)
            try await engine.prepare(model: settings.model) { [weak self] msg, frac in
                Task { @MainActor in self?.status = .preparing(msg, frac) }
            }

            engine.sink.reset()
            // AFTER prepare: promptTokens needs the loaded tokenizer, and returns nil silently
            // if asked before the model exists.
            promptTokens = engine.promptTokens(
                for: PackManager.shared.mergedVocabulary(userVocab: settings.customVocabulary))
            language = settings.language == "auto" ? nil : settings.language

            startedAt = Date()
            sessionID = UUID()
            t0 = CACurrentMediaTime()
            clock = SessionClock(t0: t0)
            bookmarks = []
            bookmarkCount = 0
            frames = []
            frameCount = 0
            segments = []
            hypothesis = ""

            let folder = Self.makeUniqueSessionFolder(date: startedAt)
            dir = folder

            // Recovery state first, so a kill in the next millisecond is still recoverable.
            persistRecoveryState()

            silence = SilenceMonitor(enabled: settings.autoPauseEnabled,
                                     pauseAfter: settings.autoPauseSeconds)
            stall = StallMonitor()
            pauseKind = nil

            // The capture chain. The writer is teed off the SAME post-gate samples the sink gets,
            // so a paused stretch is absent from BOTH and they can never disagree about the timeline.
            let audioOut: any SampleReceiver
            if let w = try? StreamingAudioWriter(sessionDir: folder) {
                writer = w
                audioOut = SampleTee(engine.sink, w)
            } else {
                writer = nil
                audioOut = engine.sink
            }
            let g = CaptureGate(downstream: audioOut)
            gate = g

            mic.onRestart = { [weak self] reason in
                Task { @MainActor in self?.note("Microphone reconnected — \(reason)") }
            }
            mic.onFailure = { [weak self] message in
                Task { @MainActor in self?.fail(message) }
            }
            try await mic.start(sink: g)
            stall.start(now: CACurrentMediaTime())      // arm AFTER capture is live

            attachStreamer()

            isRecording = true
            status = .recording
            startTick()
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func attachStreamer() {
        guard let s = engine.makeStreamer(language: language, promptTokens: promptTokens,
                                          onUpdate: { [weak self] live in
            Task { @MainActor in
                guard let self, self.isRecording else { return }   // drop late updates
                self.segments = live.confirmed
                self.hypothesis = live.hypothesis
            }
        }) else { return }
        streamer = s
        streamTask = Task { await s.run() }
    }

    /// `DocumentBuilder.makeSessionFolder` has no uniquing — two sessions in the same wall-clock
    /// second silently share a folder and the second overwrites the first. Rare on a Mac; much less
    /// rare on a phone, where a mis-tap can start and restart within a second.
    private static func makeUniqueSessionFolder(date: Date) -> URL {
        let base = DocumentBuilder.makeSessionFolder(date: date)
        let fm = FileManager.default
        guard SessionPaths.isSessionFolder(base)
                || fm.fileExists(atPath: base.appendingPathComponent(RecoveryState.filename).path)
        else { return base }
        for n in 2...99 {
            let candidate = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent) (\(n))", isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) {
                try? fm.createDirectory(at: candidate, withIntermediateDirectories: true)
                return candidate
            }
        }
        return base
    }

    // MARK: - Pause / resume

    func pause(_ kind: PauseKind = .user) {
        guard isRecording, !isPaused else { return }
        let now = CACurrentMediaTime()
        pauseKind = kind
        clock?.pause(now: now)
        gate?.close()
        level = 0            // the gate's level FREEZES rather than decaying; zero it explicitly
        status = .paused(kind)
        persistRecoveryState()
    }

    func resume() {
        guard isRecording, isPaused else { return }
        let now = CACurrentMediaTime()
        // Pre-roll is replayed ONLY for an automatic (silence) resume. Audio captured while the
        // user's session was held — a phone call, a manual pause — must never enter the transcript.
        let replay = (pauseKind == .silence)
        clock?.resume(now: now)
        gate?.open(flushPreroll: replay)
        pauseKind = nil
        silence.reset()
        quietSeconds = 0
        stall.start(now: now)     // re-arm: the stall reference is stale after a held stretch
        status = .recording
        persistRecoveryState()
    }

    func addBookmark() {
        guard let clock else { return }
        bookmarks.append(Bookmark(time: clock.time(now: CACurrentMediaTime())))
        bookmarkCount = bookmarks.count
    }

    // MARK: - The tick

    private func startTick() {
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func onTick() {
        guard isRecording, let clock else { return }
        let now = CACurrentMediaTime()
        level = isPaused ? 0 : engine.sink.recentRMS()
        elapsed = clock.time(now: now)
        updateAutoPause(now: now)
        updateCaptureHealth(now: now)
    }

    private func updateAutoPause(now: TimeInterval) {
        guard isRecording, !busy else { return }
        // The PRE-gate level, so silence can be heard returning while the gate is shut.
        let input = gate?.level ?? 0
        switch silence.update(level: input, now: now, paused: isPaused, reason: capturePauseReason) {
        case .autoPause:  pause(.silence)
        case .autoResume: resume()
        case .none:       break
        }
        quietSeconds = Int(silence.quietSeconds(now: now))
    }

    private func updateCaptureHealth(now: TimeInterval) {
        // `!isPaused` is REQUIRED on iOS and absent on macOS, deliberately. A Mac pause closes the
        // gate but leaves capture running, so `lastDeliveryAt` keeps advancing. An iOS interruption
        // STOPS the engine — delivery freezes, and without this guard the watchdog would fire three
        // seconds later and try to rebuild capture into a deactivated audio session, which cannot
        // succeed. It looks like "recording randomly dies after phone calls".
        guard isRecording, !busy, !isPaused else { return }
        if stall.shouldRecover(lastDelivery: gate?.lastDeliveryAt, now: now) {
            mic.forceRestart(reason: "no microphone audio for 3s")
        }
    }

    // MARK: - Stop

    @discardableResult
    func stop() async -> URL? {
        guard isRecording, !busy else { return nil }
        busy = true
        isRecording = false                 // early, so late stream updates drop
        defer { busy = false }

        tick?.invalidate(); tick = nil
        // A second close() while already paused WIPES the retained pre-roll, so audio captured
        // during a pause can never reach the saved session.
        if isPaused { gate?.close() }
        pauseKind = nil

        mic.onRestart = nil
        mic.onFailure = nil
        mic.stop()
        mic.deactivateAudioSession()
        gate = nil

        let live = await streamer?.snapshotSegments() ?? []
        await streamer?.stop()
        await streamTask?.value
        streamer = nil; streamTask = nil

        status = .finalizing
        guard let folder = dir else { status = .idle; return nil }

        // Close the incremental file and convert it to the session's audio.m4a. Doing this BEFORE
        // the transcript write means a crash from here on still leaves playable audio.
        let audioName = writer?.finish()?.lastPathComponent
        writer = nil

        let duration = engine.sink.snapshot().isEmpty
            ? nil : Double(engine.sink.snapshot().count) / 16_000

        // Safety-net save: everything after this is best-effort.
        DocumentBuilder.writeSession(SessionDoc(meta: meta(audioFile: audioName, duration: duration),
                                                segments: live, frames: frames), to: folder)

        var finalSegments = live
        if let better = try? await engine.finalPassSegments(language: language, promptTokens: promptTokens),
           !better.isEmpty {
            finalSegments = better
        }
        DocumentBuilder.writeSession(SessionDoc(meta: meta(audioFile: audioName, duration: duration),
                                                segments: finalSegments, frames: frames), to: folder)

        // The session is now complete on disk, so it is no longer a recovery candidate.
        RecoveryState.clear(in: folder)
        SessionStore.postSessionSaved(folder)

        // A hot device skips the optional passes rather than adding load on top of the heat.
        let wantDiarize = settings.diarizationEnabled && !thermallyThrottled
        let diarSamples: [Float] = wantDiarize ? engine.sink.snapshot() : []   // snapshot ON-MAIN
        let wantCleanup = settings.cleanupEnabled
        Task.detached(priority: .utility) {
            SearchIndex.shared.index(sessionDir: folder)
            SessionStore.ensureSessionID(dir: folder)
            await SessionStore.ensureTitle(dir: folder)
            if wantDiarize { await DiarizationPass.run(dir: folder, samples: diarSamples) }
            if wantCleanup { await CleanupPass.run(dir: folder) }
        }

        status = .idle
        dir = nil
        return folder
    }

    private func meta(audioFile: String?, duration: Double?) -> SessionMeta {
        SessionMeta(id: sessionID,
                    date: startedAt,
                    sourceLabel: "This room",
                    modelName: settings.model,
                    audioFile: audioFile,
                    durationSeconds: duration,
                    bookmarks: bookmarks,
                    language: (language != nil && language != "en") ? language : nil)
    }

    private func persistRecoveryState() {
        guard let folder = dir, let clock else { return }
        RecoveryState(sessionID: sessionID,
                      startedAt: startedAt,
                      accumulatedPause: clock.totalPaused(now: CACurrentMediaTime()),
                      sourceLabel: "This room",
                      modelName: settings.model,
                      language: language).write(to: folder)
    }

    // MARK: - Slide frames (§9)

    /// Append a captured slide to the timeline.
    ///
    /// The result must be indistinguishable on disk from what Phase 2's Mac renderer expects: the
    /// same `FrameEvent` shape, the same `images/slide-000N.png` relative path, the same OCR text
    /// reaching the search index through the transcript. `--selftest-frames` defines correct.
    ///
    /// **Recording is not interrupted.** This runs alongside it; the frame's time comes from the
    /// same `SessionClock` the audio and every bookmark use, so it lands against the words that
    /// were being spoken when the shutter fired.
    @discardableResult
    func appendFrame(_ image: CGImage) async -> FrameEvent? {
        guard let folder = dir, let clock else { return nil }
        // Stamp the time FIRST — OCR takes a moment, and the frame belongs where the shutter was.
        let at = clock.time(now: CACurrentMediaTime())

        guard let png = SlideOCR.pngData(from: image) else { return nil }
        let index = frames.count + 1
        let relative = SlideOCR.frameRelativePath(index: index)
        let target = folder.appendingPathComponent(relative)
        do {
            // `images/` is created lazily, on first frame write — never up front.
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try SessionIO.writeData(png, to: target)      // routed so at-rest encryption is transparent
        } catch {
            NSLog("[Recording] slide write failed: \(error)")
            return nil
        }

        // `.accurate` for the frame that lands on the timeline (the live read-out used `.fast`).
        let text = await SlideOCR.recognize(cgImage: image)
        let event = FrameEvent(time: at, imagePath: relative, text: text)
        frames.append(event)
        frameCount = frames.count
        return event
    }

    /// A session has video OR frames, never both. An imported video session cannot take slides, so
    /// the Slide button is disabled there rather than failing at write time.
    var canCaptureSlides: Bool { isRecording }

    // MARK: - Hooks used by the interruption handlers (see RecordingModel+Interruptions)

    /// Keep notification tokens alive for the model's lifetime.
    func retainObservers(_ tokens: [NSObjectProtocol]) { observers.append(contentsOf: tokens) }

    /// Why we are currently paused, for handlers that must only act on their own pause.
    var currentPauseKind: PauseKind? { pauseKind }

    /// Rebuild capture around a freshly configured session, REUSING the existing `CaptureGate`.
    ///
    /// Never allocate a fresh gate mid-session: a new one starts OPEN, so a paused session would
    /// silently reopen and record audio the user had held. Pause state, level history and
    /// `lastDeliveryAt` all live on the gate and must survive the engine being torn down.
    func restartCapture(reason: String) {
        guard isRecording else { return }
        mic.forceRestart(reason: reason)
        stall.start(now: CACurrentMediaTime())
    }

    // MARK: - Thermal + memory (H4)

    /// Watch for the phone getting hot. Recording for an hour with a large model in a pocket is a
    /// real scenario, and "gets slower and hotter until iOS kills it" is the failure to avoid.
    func installPressureObservers() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleThermalChange() }
        }
    }

    private func handleThermalChange() {
        guard isRecording else { return }
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            // Back off rather than compete with the system for the CPU. Diarization is the
            // expensive optional pass, so it is the first thing to go.
            thermallyThrottled = true
            note("thermal state serious — easing off")
        case .critical:
            // Finish cleanly while we still can, and say why, rather than being killed mid-session.
            note("thermal state critical — finalising the recording")
            pendingStopReason = "Your iPhone got too warm, so Said finished the recording and saved it."
            Task { await stop() }
        default:
            thermallyThrottled = false
        }
    }

    /// True while the device is too warm for the optional post-passes.
    private(set) var thermallyThrottled = false
    /// Set when the app stops a recording on its own, so the UI can explain itself.
    private(set) var pendingStopReason: String?

    private func note(_ message: String) { NSLog("[Recording] \(message)") }

    private func fail(_ message: String) {
        status = .failed(message)
        isRecording = false
        tick?.invalidate(); tick = nil
    }
}
