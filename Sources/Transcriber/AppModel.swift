import SwiftUI
import AppKit
import KeyboardShortcuts
import UniformTypeIdentifiers
import QuartzCore

// MARK: - Domain types

enum AudioSource: String, CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case micPlusSystem            // additive; off by default (mic + system mixed into the shared sink)

    var id: String { rawValue }
    var label: String {
        switch self {
        case .microphone: return "Mic"
        case .systemAudio: return "System Audio"
        case .micPlusSystem: return "Mic + System"
        }
    }
    var shortLabel: String {
        switch self {
        case .microphone: return "Mic"
        case .systemAudio: return "System"
        case .micPlusSystem: return "Both"
        }
    }
    var symbol: String {
        switch self {
        case .microphone: return "mic"
        case .systemAudio: return "speaker.wave.2"
        case .micPlusSystem: return "waveform.badge.mic"
        }
    }
    var usesMic: Bool { self != .systemAudio }
    var usesSystem: Bool { self != .microphone }
}

enum WhisperModel: String, CaseIterable, Identifiable {
    case baseEn = "openai_whisper-base.en"
    case smallEn = "openai_whisper-small.en"
    case base = "openai_whisper-base"            // multilingual sibling of base.en
    case small = "openai_whisper-small"          // multilingual sibling of small.en
    case largeV3Turbo = "openai_whisper-large-v3_turbo"

    var id: String { rawValue }
    var shortName: String {
        switch self {
        case .baseEn: return "base.en"
        case .smallEn: return "small.en"
        case .base: return "base"
        case .small: return "small"
        case .largeV3Turbo: return "large-v3-turbo"
        }
    }
    var label: String {
        switch self {
        case .baseEn: return "base.en — fastest, good for real-time"
        case .smallEn: return "small.en — balanced"
        case .base: return "base — fastest multilingual"
        case .small: return "small — balanced multilingual"
        case .largeV3Turbo: return "large-v3-turbo — most accurate, multilingual"
        }
    }
    /// `*.en` models only transcribe English; the others accept any `DecodingOptions.language`.
    var isMultilingual: Bool {
        switch self {
        case .baseEn, .smallEn: return false
        case .base, .small, .largeV3Turbo: return true
        }
    }
    /// The same-size multilingual model to offer when a non-English language is wanted.
    var multilingualSibling: WhisperModel {
        switch self {
        case .baseEn: return .base
        case .smallEn: return .small
        default: return self
        }
    }
}

/// A user-authored summary template (Feature D2). Persisted as JSON in UserDefaults; outputs are
/// cached in `SessionMeta.summaries` under `cacheKey` (namespaced so it can't collide with the
/// built-in `SummaryStyle` raw values).
struct CustomSummaryMode: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var instructions: String
    var id: String { name }
    var cacheKey: String { "custom:\(name)" }
}

enum EngineStatus: Equatable {
    case idle
    case preparingModel(String)
    case recording
    case paused
    case finalizing
    case error(String)

    var menuText: String {
        switch self {
        case .idle: return "Idle"
        case .preparingModel(let m): return m
        case .recording: return "Recording…"
        case .paused: return "Paused"
        case .finalizing: return "Finalizing…"
        case .error(let e): return "Error: \(e)"
        }
    }

    var isBusyPreparing: Bool {
        if case .preparingModel = self { return true }
        if case .finalizing = self { return true }
        return false
    }

    /// True only while preparing/downloading the model (NOT finalizing) — drives the `downloading`
    /// UI state, so finalizing keeps the transcript on screen rather than the centered ring.
    var isPreparing: Bool {
        if case .preparingModel = self { return true }
        return false
    }
}

/// The four window states the redesign is driven by.
enum UIState { case idle, downloading, recording, summary }

/// High-frequency recording HUD (live meter level + elapsed seconds), kept on its own
/// ObservableObject so ~12 Hz updates only re-render the toolbar live cluster, not the transcript.
@MainActor
final class RecordingHUD: ObservableObject {
    @Published var level: Float = 0
    @Published var elapsed: Int = 0
    /// Seconds the capture has been delivering pure digital silence (0 = receiving audio).
    /// Surfaced in the status bar so a dead capture is visible DURING the session instead of
    /// being discovered afterwards as a transcript full of `[BLANK_AUDIO]`.
    @Published var silentSeconds: Int = 0
    /// Seconds of continuous QUIET (below the audible threshold, not necessarily digital zeros).
    /// Drives the "auto-pausing in Ns" countdown; distinct from `silentSeconds`, which specifically
    /// means "the capture handed us nothing at all".
    @Published var quietSeconds: Int = 0
}

// MARK: - App model

@MainActor
final class AppModel: ObservableObject {
    /// Single shared instance so both the SwiftUI scenes and the AppDelegate launch hook
    /// reference the same model regardless of @StateObject creation timing.
    static let shared = AppModel()

    @Published var transcript: String = ""          // full concatenation (save / summarize) — unchanged semantics
    @Published var isRecording: Bool = false
    @Published var status: EngineStatus = .idle
    @Published var lastSavedURL: URL?

    /// Paused: the session is still open (still `isRecording`) but capture is gated off, so no
    /// samples enter the recording and the timeline does not advance.
    @Published var isPaused: Bool = false
    @Published var pauseReason: PauseReason? = nil
    /// Transient status line for capture events the user should see but never be blocked by
    /// ("Output device changed — capture continues"). Auto-clears.
    @Published var captureNotice: String? = nil

    // Live "settling" view: confirmed (timestamped) segments + the dimmed in-flight tail.
    @Published var displaySegments: [TranscriptSegment] = []
    @Published var hypothesisText: String = ""
    @Published var showingSummary: Bool = false
    @Published var downloadFraction: Double? = nil   // 0…1 while downloading the model

    @Published var summary: String = ""
    @Published var isSummarizing: Bool = false

    /// Live meter + timer (own object so its 12 Hz updates don't re-render the transcript).
    let hud = RecordingHUD()

    /// The single UI state the window renders from, derived from real signals.
    var uiState: UIState {
        if showingSummary { return .summary }
        if isRecording { return .recording }
        if status.isPreparing { return .downloading }
        return .idle
    }

    var wordCount: Int {
        transcript.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    @Published var source: AudioSource {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "source") }
    }
    @Published var model: WhisperModel {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "model") }
    }

    // MARK: Prompt-2 settings (all additive; neutral defaults preserve byte-identical capture)
    @Published var saveAudioEnabled: Bool {            // B3: persist source audio for playback (default ON)
        didSet { UserDefaults.standard.set(saveAudioEnabled, forKey: "saveAudioEnabled") }
    }
    /// Capture system audio with a Core Audio process tap (macOS 14.2+) instead of ScreenCaptureKit.
    /// ON by default: the SCK filter is display-scoped and silently drops any process without a
    /// window on the captured display, while the tap hears the whole audio engine regardless of
    /// window, display, output device, volume, or mute. Off ⇒ the original SCK path verbatim.
    @Published var useProcessTap: Bool {
        didSet { UserDefaults.standard.set(useProcessTap, forKey: "useProcessTap") }
    }
    @Published var customVocabulary: [String] {        // C2: decoding bias terms ([] = exact no-op)
        didSet { UserDefaults.standard.set(customVocabulary, forKey: "customVocabulary") }
    }
    /// Auto-pause a recording after a stretch of silence, and auto-resume when audio returns.
    /// ON by default: a muted call, a paused video, or a break between talkers otherwise records
    /// minutes of nothing (and transcribes it as `[BLANK_AUDIO]`).
    @Published var autoPauseEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoPauseEnabled, forKey: "autoPauseEnabled")
            silence.enabled = autoPauseEnabled
        }
    }
    /// How long silence must last before the automatic pause fires.
    @Published var autoPauseSeconds: Double {
        didSet {
            UserDefaults.standard.set(autoPauseSeconds, forKey: "autoPauseSeconds")
            silence.pauseAfter = autoPauseSeconds
        }
    }
    /// Stage 2 / Feature B: the user's custom vocabulary UNIONED with every enabled vertical pack's
    /// vocabulary (deduped). With no user terms AND no enabled pack this is [] → promptTokens nil →
    /// byte-identical no-op. This is what actually feeds the streaming + finalPass bias.
    var effectiveVocabulary: [String] { PackManager.shared.mergedVocabulary(userVocab: customVocabulary) }
    @Published var defaultSummaryStyle: SummaryStyle { // A3
        didSet { UserDefaults.standard.set(defaultSummaryStyle.rawValue, forKey: "defaultSummaryStyle") }
    }
    @Published var obsidianVaultPath: String {         // C3 (empty = not configured)
        didSet { UserDefaults.standard.set(obsidianVaultPath, forKey: "obsidianVaultPath") }
    }

    // MARK: Stage-1 settings (all additive; defaults preserve byte-identical output)
    /// Feature A: on-device speaker diarization (FluidAudio). OFF by default — no model download,
    /// no labels, byte-identical sessions.
    @Published var diarizationEnabled: Bool {
        didSet { UserDefaults.standard.set(diarizationEnabled, forKey: "diarizationEnabled") }
    }
    /// Feature B: "auto" or an ISO code (en/es/fr/…). Default "en" — the exact pre-Stage-1 pin.
    /// Only meaningful with a multilingual model; `effectiveLanguageSetting` pins "en" otherwise.
    @Published var transcriptionLanguage: String {
        didSet { UserDefaults.standard.set(transcriptionLanguage, forKey: "transcriptionLanguage") }
    }
    /// Feature D1: store an additional per-segment cleaned form (fillers removed, punctuation fixed).
    /// OFF by default; the verbatim transcript.md is NEVER touched either way.
    @Published var cleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(cleanupEnabled, forKey: "cleanupEnabled") }
    }
    /// Feature D2: user-authored summary templates (JSON in UserDefaults; ships empty).
    @Published var customSummaryModes: [CustomSummaryMode] {
        didSet {
            if let data = try? JSONEncoder().encode(customSummaryModes) {
                UserDefaults.standard.set(data, forKey: "customSummaryModes")
            }
        }
    }
    // MARK: Stage-2 settings (Feature B packs + Feature C retention/encryption; all additive)
    /// Feature B: enabled vertical-pack ids (mirrors PackManager; merges vocab + surfaces templates).
    @Published var enabledPackIDs: Set<String> {
        didSet { PackManager.shared.enabledPackIDs = enabledPackIDs }
    }
    /// Feature C1: retention policy (auto-delete to Trash). Disabled by default ⇒ launch sweep no-op.
    @Published var retentionPolicy: RetentionPolicy {
        didSet { Retention.policy = retentionPolicy }
    }
    /// Feature C4: require Touch ID to unlock encrypted transcripts (only meaningful when encrypted).
    @Published var encryptionRequireTouchID: Bool {
        didSet { SessionIO.requireTouchID = encryptionRequireTouchID }
    }
    /// Feature C4: reflects SessionIO.isEncryptionEnabled. Changed only via `setEncryption(_:)` (which
    /// runs the encrypt/decrypt migration off-main), never a raw toggle didSet.
    @Published var encryptionEnabled: Bool = SessionIO.isEncryptionEnabled
    @Published var encryptionBusy: Bool = false
    @Published var encryptionStatus: String? = nil

    /// Feature C: calendar-aware capture. OFF by default — when off, no EKEventStore is ever created.
    @Published var calendarCaptureEnabled: Bool {
        didSet {
            UserDefaults.standard.set(calendarCaptureEnabled, forKey: "calendarCaptureEnabled")
            updateCalendarMonitor()
        }
    }
    /// false = "Prompt me when a meeting starts" (default), true = auto-start recording.
    @Published var calendarAutoStart: Bool {
        didSet { UserDefaults.standard.set(calendarAutoStart, forKey: "calendarAutoStart") }
    }
    /// Source used for calendar-triggered recordings (System Audio default, or Mic + System).
    @Published var calendarCaptureSource: AudioSource {
        didSet { UserDefaults.standard.set(calendarCaptureSource.rawValue, forKey: "calendarCaptureSource") }
    }
    /// How early (seconds before event start) a meeting trigger fires.
    @Published var calendarLeadSeconds: Double {
        didSet { UserDefaults.standard.set(calendarLeadSeconds, forKey: "calendarLeadSeconds") }
    }

    /// Transient UI: the resolved/detected session language ("Detected: Español"), recording state only.
    @Published var sessionLanguageLabel: String? = nil
    /// Transient UI: a calendar meeting awaiting the user's Start/Ignore (prompt mode).
    @Published var meetingPrompt: MeetingCandidate? = nil
    /// Transient UI: title of a meeting recording that auto-started (dismissible banner).
    @Published var autoStartedMeeting: String? = nil
    /// Last ~8 sessions for the menu's Recent submenu (cached; refreshed on save, off the main thread).
    @Published var recentSessions: [SessionInfo] = []
    /// Transient: session-time of the most recent live bookmark (drives a small HUD confirmation).
    @Published var lastBookmarkAt: TimeInterval? = nil

    // MARK: Screen recording (per-session, persisted defaults)

    /// Whether the NEXT session also records the screen. Set by the Record Screen button / ⌥⌘S, or
    /// left on in Settings for someone who always records both.
    @Published var screenRecordingEnabled: Bool {
        didSet { UserDefaults.standard.set(screenRecordingEnabled, forKey: "screenRecordingEnabled") }
    }
    /// What gets recorded: a display, a window, or one app's windows.
    @Published var screenTarget: ScreenTarget {
        didSet { UserDefaults.standard.set(screenTarget.persisted, forKey: "screenTarget") }
    }
    @Published var screenQuality: ScreenQuality {
        didSet { UserDefaults.standard.set(screenQuality.rawValue, forKey: "screenQuality") }
    }
    /// Audio used when a recording is STARTED from the Record Screen button — a screen recording
    /// with no system audio would miss the sound of whatever is on screen, so this defaults to
    /// Mic + System rather than inheriting a mic-only pick.
    @Published var screenAudioSource: AudioSource {
        didSet { UserDefaults.standard.set(screenAudioSource.rawValue, forKey: "screenAudioSource") }
    }
    @Published var availableTargets: [ScreenTargetOption] = []
    /// A ~1 Hz downscaled frame of what is being recorded (recording state only).
    @Published var screenPreview: NSImage?
    /// True while the live session is also recording the screen.
    @Published private(set) var isRecordingScreen = false
    @Published var lastSessionDir: URL?
    /// Whether the last finished session has a video (drives the "open it" affordances).
    @Published var lastSessionHasVideo = false
    @Published var isExporting = false

    private let engine = TranscriptionEngine()
    private let mic = AudioCaptureMic()
    private let system = AudioCaptureSystem()
    /// `AudioCaptureProcessTap` while the tap backend is the live system-audio source. Held as
    /// `AnyObject` because the type is `@available(macOS 14.2)` and the deployment target is 14.0.
    private var processTap: AnyObject?
    private var streamer: StreamingTranscriber?
    private var streamTask: Task<Void, Never>?
    private var busy = false
    private var hudTimer: Timer?
    private var digitalSilenceSince: Date?
    private var recordingStart = Date()

    // Pause / auto-pause / capture-health state (see CaptureControl.swift)
    /// The valves every capture source pushes through. Pausing closes them; the watchdog reads
    /// their level + last-delivery timestamps. nil outside a session.
    private var micGate: CaptureGate?
    private var systemGate: CaptureGate?
    private var clock = SessionClock(t0: 0)
    private var silence = SilenceMonitor()
    private var micStall = StallMonitor()
    private var systemStall = StallMonitor()
    /// A recovery (capture restart) is in flight — suppresses the watchdog and re-entrancy.
    private var recovering = false
    /// Consecutive failed recoveries for the system source; a session is only ended after several.
    private var systemRecoveryFailures = 0
    /// Bounded rebuilds triggered by an alive-but-silent system capture (see `updateCaptureHealth`).
    private var silentRebuilds = 0
    private var lastSilentRebuildAt: TimeInterval = 0
    private var noticeClearTask: Task<Void, Never>?
    /// Error to show once the stop flow finishes (it owns `status` while finalizing).
    private var pendingStopMessage: String?

    // Screen-recording session state
    private var screenRecorder: ScreenRecorder?
    /// The finished video for the session being saved (nil when the screen wasn't recorded).
    private var screenResult: ScreenRecordingResult?
    /// Finalization of a video whose capture died mid-session — awaited before the session is saved,
    /// so the file is always linked in `session.json` rather than orphaned in the folder.
    private var screenFinishTask: Task<Void, Never>?
    /// One-shot "record the screen this session" (⌥⌘S / the Record Screen button), independent of the
    /// persisted Settings default.
    private var screenOverride: Bool?
    private var sessionDir: URL?
    private var sessionT0: TimeInterval = 0
    private var sessionStartDate = Date()

    // Prompt-2 session state
    private var mixer: AudioMixer?                 // non-nil only for the .micPlusSystem source
    private var sessionBookmarks: [Bookmark] = []  // live ⌥⌘B marks (seconds from T0)
    private var sessionPromptTokens: [Int]?        // custom-vocab decode bias snapshot for this session

    // Stage-1 session state
    private var sessionSource: AudioSource = .microphone  // the source THIS session records with
    private var sourceOverride: AudioSource?       // one-shot override (calendar-triggered recordings)
    private var sessionLanguage: String?           // resolved language code for this session ("en" default)
    private var detectTask: Task<Void, Never>?     // the one-shot "auto" language detection
    private var pendingTitleSeed: String?          // meeting title seeded into the session (Feature C)
    private var calendarMonitor: CalendarMonitor?  // non-nil ONLY while calendarCaptureEnabled

    var canExport: Bool { lastSessionDir != nil }

    /// The language SETTING in effect: `*.en` models always pin "en" (English-only decoder — the
    /// Settings UI also guards this); multilingual models honor `transcriptionLanguage` ("auto" or code).
    var effectiveLanguageSetting: String { model.isMultilingual ? transcriptionLanguage : "en" }

    /// Curated language choices for the Settings picker ("auto" + a top set of ISO codes).
    static let languageOptions: [(code: String, label: String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("ja", "Japanese"), ("zh", "Chinese"), ("ko", "Korean"), ("hi", "Hindi"),
        ("ar", "Arabic"), ("ru", "Russian"),
    ]
    static func languageName(_ code: String) -> String {
        languageOptions.first { $0.code == code }?.label
            ?? Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    private init() {
        let d = UserDefaults.standard
        source = AudioSource(rawValue: d.string(forKey: "source") ?? "") ?? .microphone
        model = WhisperModel(rawValue: d.string(forKey: "model") ?? "") ?? .baseEn
        screenRecordingEnabled = d.bool(forKey: "screenRecordingEnabled")
        screenTarget = ScreenTarget(persisted: d.string(forKey: "screenTarget") ?? "main")
        screenQuality = ScreenQuality(rawValue: d.string(forKey: "screenQuality") ?? "") ?? .balanced
        screenAudioSource = AudioSource(rawValue: d.string(forKey: "screenAudioSource") ?? "") ?? .micPlusSystem
        saveAudioEnabled = (d.object(forKey: "saveAudioEnabled") as? Bool) ?? true
        useProcessTap = (d.object(forKey: "useProcessTap") as? Bool) ?? true
        customVocabulary = (d.object(forKey: "customVocabulary") as? [String]) ?? []
        autoPauseEnabled = (d.object(forKey: "autoPauseEnabled") as? Bool) ?? true
        autoPauseSeconds = (d.object(forKey: "autoPauseSeconds") as? Double) ?? AudioActivity.defaultAutoPauseSeconds
        defaultSummaryStyle = SummaryStyle(rawValue: d.string(forKey: "defaultSummaryStyle") ?? "") ?? .tldr
        obsidianVaultPath = d.string(forKey: "obsidianVaultPath") ?? ""
        diarizationEnabled = d.bool(forKey: "diarizationEnabled")
        transcriptionLanguage = d.string(forKey: "transcriptionLanguage") ?? "en"
        cleanupEnabled = d.bool(forKey: "cleanupEnabled")
        customSummaryModes = d.data(forKey: "customSummaryModes")
            .flatMap { try? JSONDecoder().decode([CustomSummaryMode].self, from: $0) } ?? []
        enabledPackIDs = PackManager.shared.enabledPackIDs
        retentionPolicy = Retention.policy
        encryptionRequireTouchID = SessionIO.requireTouchID
        encryptionEnabled = SessionIO.isEncryptionEnabled
        calendarCaptureEnabled = d.bool(forKey: "calendarCaptureEnabled")
        calendarAutoStart = d.bool(forKey: "calendarAutoStart")
        calendarCaptureSource = AudioSource(rawValue: d.string(forKey: "calendarCaptureSource") ?? "") ?? .systemAudio
        calendarLeadSeconds = (d.object(forKey: "calendarLeadSeconds") as? Double) ?? 60

        WindowManager.shared.model = self
        debugLog("AppModel.init")

        silence = SilenceMonitor(enabled: autoPauseEnabled, pauseAfter: autoPauseSeconds)

        // Global hotkeys — fire from any app (Carbon RegisterEventHotKey → no permission).
        // Routed through `fireOnce` because the same physical press ALSO reaches the menu item's
        // key equivalent while Transcriber is frontmost (see MenuCommands.swift): two paths, one
        // intent. Buttons call toggle()/togglePause()/… directly and are unaffected.
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            Task { @MainActor in self?.fireOnce("toggle") { self?.toggle() } }
        }
        KeyboardShortcuts.onKeyDown(for: .togglePause) { [weak self] in
            Task { @MainActor in self?.fireOnce("pause") { self?.togglePause() } }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleScreenRecording) { [weak self] in
            Task { @MainActor in self?.fireOnce("screen") { self?.toggleScreenRecording() } }
        }
        KeyboardShortcuts.onKeyDown(for: .addBookmark) { [weak self] in
            Task { @MainActor in self?.fireOnce("bookmark") { self?.addBookmark() } }
        }
    }

    /// Collapses the two keyboard paths (global Carbon hotkey + main-menu key equivalent) that fire
    /// for a single press while the app is frontmost. Keyed per action, so ⌥⌘T and ⌥⌘B never mask
    /// each other.
    private var lastKeyFire: [String: Date] = [:]
    func fireOnce(_ id: String, within: TimeInterval = 0.35, _ action: () -> Void) {
        let now = Date()
        if let last = lastKeyFire[id], now.timeIntervalSince(last) < within { return }
        lastKeyFire[id] = now
        action()
    }

    /// Called from AppDelegate at launch (a reliable hook, unlike @StateObject init timing).
    /// This is a menu-bar-only app (no Dock icon), so we open the Transcript window — which is a
    /// full control surface — on launch. Without this a new user sees "nothing happen" (no Dock
    /// icon, no window, just a small menu-bar icon) and assumes the app didn't open.
    func onLaunch() {
        debugLog("onLaunch")
        WindowManager.shared.showTranscript()

        // Keep the menu's Recent-Sessions cache fresh whenever any session is saved/updated.
        NotificationCenter.default.addObserver(forName: .transcriberSessionSaved, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshRecentSessions() }
        }

        // First run: walk the user through Microphone + Screen Recording (+ optional Notifications).
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            WindowManager.shared.showOnboarding()
        }

        // Calendar-aware capture (Feature C): only ever touches EventKit when the toggle is on.
        updateCalendarMonitor()

        // One-time, idempotent migration of legacy flat *.md files into the unified folder layout,
        // then (re)build the on-device search index from disk. Off the main thread; the Library and
        // index pick it up via the .transcriberSessionSaved notification. No new permissions.
        Task.detached(priority: .utility) {
            let result = SessionStore.migrateLegacyFlatFiles()
            if result.legacyFound > 0 { NSLog("[Migrate] \(result.summary)") }
            // Feature C1: retention sweep (idempotent; a no-op unless auto-delete is enabled). Runs
            // BEFORE the index rebuild so trashed sessions never enter the index.
            Retention.sweep()
            SearchIndex.shared.rebuildFromDisk()
            await MainActor.run {
                NotificationCenter.default.post(name: .transcriberSessionSaved, object: nil)
            }
        }
    }

    /// Recompute the Recent-Sessions cache off the main thread (8 newest).
    func refreshRecentSessions() {
        Task.detached(priority: .utility) {
            let recent = Array(SessionStore.allSessions().prefix(8))
            await MainActor.run { self.recentSessions = recent }
        }
    }

    // MARK: Stage-2 actions (encryption migration + manual retention purge)

    /// Enable/disable encryption-at-rest, running the encrypt/decrypt migration off the main thread
    /// (copy-then-verify-then-replace + one-time backup). Never loses data; surfaces a clear status.
    func setEncryption(_ on: Bool) {
        guard on != SessionIO.isEncryptionEnabled, !encryptionBusy else { return }
        encryptionBusy = true
        encryptionStatus = on ? "Encrypting existing sessions…" : "Decrypting existing sessions…"
        Task.detached(priority: .utility) {
            // `let` (not a mutated var) so the value crossing into the MainActor hop is a plain
            // immutable capture — the var form is an error under the Swift 6 language mode.
            let message: String
            do {
                if on { try SessionIO.enableEncryption() } else { try SessionIO.disableEncryption() }
                SearchIndex.shared.rebuildFromDisk()
                message = on ? "Encrypted at rest." : "Decrypted — stored as plain files."
            } catch {
                message = "Failed: \(error.localizedDescription)"
            }
            await MainActor.run {
                self.encryptionEnabled = SessionIO.isEncryptionEnabled
                self.encryptionBusy = false
                self.encryptionStatus = message
                NotificationCenter.default.post(name: .transcriberSessionSaved, object: nil)
            }
        }
    }

    /// Manual purge: delete all saved audio (keeps transcripts). Off-main; refreshes the Library.
    func purgeAllAudio() {
        Task.detached(priority: .utility) {
            let n = Retention.deleteAllAudio()
            await MainActor.run {
                self.encryptionStatus = "Deleted audio from \(n) session\(n == 1 ? "" : "s")."
                NotificationCenter.default.post(name: .transcriberSessionSaved, object: nil)
            }
        }
    }

    /// Manual purge: trash transcripts older than `days` (skips retention-locked sessions).
    func purgeOlderThan(days: Int) {
        Task.detached(priority: .utility) {
            let n = Retention.deleteOlderThan(days: days)
            await MainActor.run {
                self.encryptionStatus = "Trashed \(n) session\(n == 1 ? "" : "s") older than \(days) days."
                NotificationCenter.default.post(name: .transcriberSessionSaved, object: nil)
            }
        }
    }

    // MARK: Public controls

    func toggle() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    // `busy` is a synchronous reentry gate. It is set BEFORE dispatching either flow (on the
    // MainActor, before any await), so a hotkey press during a start/stop transition is ignored
    // rather than spawning a second flow. This prevents startFlow and stopFlow — which share one
    // WhisperKit instance — from ever running (and transcribing) concurrently.
    func startRecording() {
        guard !busy, !isRecording else { return }
        busy = true
        Task { await startFlow() }
    }

    func stopRecording() {
        guard !busy, isRecording else { return }
        busy = true
        isRecording = false   // set early so late streaming updates are ignored
        Task { await stopFlow() }
    }

    // MARK: Flows

    private func startFlow() async {
        // `busy` was already set synchronously by startRecording(); clear it when setup finishes
        // (recording then runs with busy == false so Stop is accepted).
        defer { busy = false }

        do {
            status = .preparingModel("Preparing \(model.shortName)…")
            downloadFraction = nil
            try await engine.prepare(model: model.rawValue) { [weak self] msg, fraction in
                Task { @MainActor in
                    guard let self, self.isRecording == false else { return }
                    self.status = .preparingModel(msg)
                    self.downloadFraction = fraction
                }
            }
            downloadFraction = nil

            engine.sink.reset()
            transcript = ""
            displaySegments = []
            hypothesisText = ""
            showingSummary = false
            summary = ""
            screenPreview = nil
            screenResult = nil
            lastSessionDir = nil
            lastSessionHasVideo = false
            sessionBookmarks = []
            lastBookmarkAt = nil
            system.onStreamStopped = nil   // clear any stale closure from a prior system/both session
            // Custom-vocab decode bias snapshot for this whole session (nil when empty → exact no-op).
            // Feature B: enabled vertical packs merge their vocabulary in here; with no user vocab AND
            // no enabled pack the union is empty → promptTokens nil → byte-identical no-op.
            sessionPromptTokens = engine.promptTokens(for: effectiveVocabulary)

            // The source for THIS session: the user's pick, or a one-shot calendar-trigger override
            // (so a meeting auto-capture can use System Audio without flipping the persisted setting).
            sessionSource = sourceOverride ?? source
            sourceOverride = nil

            // Feature B: resolve the session language once, up front. Default ("en") is byte-identical
            // to the old hard pin. "auto" (multilingual models only) defers to a one-shot detection on
            // the first seconds of audio — never per-window, so the language can't flip mid-session.
            let langSetting = effectiveLanguageSetting
            let autoDetect = (langSetting == "auto")
            sessionLanguage = autoDetect ? nil : langSetting
            sessionLanguageLabel = (!autoDetect && langSetting != "en") ? Self.languageName(langSetting) : nil

            // Single session clock T0 (monotonic): transcript segments are relative to the audio
            // buffer start (== T0) and frame events are stamped CACurrentMediaTime() - T0.
            sessionStartDate = Date()
            sessionT0 = CACurrentMediaTime()
            // The pause-aware view of that same clock: paused stretches are dropped from the audio,
            // so bookmarks / slides / the timer must all be measured with them removed.
            clock = SessionClock(t0: sessionT0)

            // Unified store: EVERY session is a folder (transcript.md + session.json), plus the
            // media it produced (audio.m4a, and screen.mp4 when the screen was recorded).
            let dir = DocumentBuilder.makeSessionFolder(date: sessionStartDate)
            sessionDir = dir

            // Screen recording is started BEFORE audio capture so a missing Screen Recording grant
            // fails the whole start cleanly, instead of leaving a running audio session with a
            // silently-dead video. Its audio is the session's own stream (the tee below).
            let wantScreen = screenOverride ?? screenRecordingEnabled
            screenOverride = nil
            screenFinishTask = nil

            var recorder: ScreenRecorder?
            if wantScreen {
                let r = ScreenRecorder(target: screenTarget, quality: screenQuality,
                                       outputURL: dir.appendingPathComponent("screen.mp4"))
                r.onPreview = { [weak self] image in
                    Task { @MainActor in self?.screenPreview = image }
                }
                r.onStopped = { [weak self] msg in
                    Task { @MainActor in self?.handleScreenStopped(msg) }
                }
                try await r.start(t0: sessionT0)
                screenRecorder = r
                recorder = r
                isRecordingScreen = true
            } else {
                screenRecorder = nil
                isRecordingScreen = false
            }

            // Where the transcription-ready samples land. With a screen recording live, a tee also
            // feeds them into the video's audio track — one capture, one stream, two consumers.
            let audioOut: any SampleReceiver = recorder.map { SampleTee(engine.sink, $0) } ?? engine.sink

            // Single-source → push straight to the shared sink (byte-identical to before). Mic+System →
            // an AudioMixer sums both streams into the same sink, feeding the unchanged streamer/finalPass.
            let micReceiver: any SampleReceiver
            let systemReceiver: any SampleReceiver
            if sessionSource == .micPlusSystem {
                let m = AudioMixer(out: audioOut)
                mixer = m
                micReceiver = m.micPort
                systemReceiver = m.systemPort
            } else {
                mixer = nil
                micReceiver = audioOut
                systemReceiver = audioOut
            }

            // Every capture pushes through a gate: the pause valve, and the probe the auto-pause +
            // watchdog read. An OPEN gate forwards the exact array it was handed, so an unpaused
            // session is byte-identical to one with no gate.
            resetPauseState()
            let micPort = CaptureGate(downstream: micReceiver)
            let systemPort = CaptureGate(downstream: systemReceiver)
            micGate = sessionSource.usesMic ? micPort : nil
            systemGate = sessionSource.usesSystem ? systemPort : nil

            switch sessionSource {
            case .microphone:
                try await startMic(into: micPort)
            case .systemAudio:
                try await startSystem(into: systemPort)
            case .micPlusSystem:
                try await startSystem(into: systemPort)
                try await startMic(into: micPort)
            }

            if autoDetect {
                // Detect-once-then-pin: the streamer attaches AFTER ~3 s of lead-in resolves the
                // language, so every streaming window + the final pass share one fixed language.
                // (The shared WhisperKit isn't transcribing yet, so detection can't collide with it.)
                detectTask = Task { [weak self] in await self?.detectLanguageThenAttachStreamer() }
            } else if !attachStreamer(language: sessionLanguage) {
                throw CaptureError.engineNotReady
            }

            isRecording = true
            status = .recording
            startHUDTimer()
        } catch {
            await teardownCaptures()
            isRecording = false
            handle(error)
        }
    }

    // MARK: Capture start / recovery
    //
    // Every capture is started through these two helpers, by `startFlow` AND by the recovery path,
    // so a mid-session restart stands the source back up exactly the way it was first built.

    /// Start the mic into `gate`, wiring the self-healing callbacks (a device switch rebuilds the
    /// engine underneath us — the session must not notice beyond a status line).
    private func startMic(into gate: CaptureGate) async throws {
        mic.onRestart = { [weak self] reason in
            Task { @MainActor in self?.noteCaptureEvent("Microphone reconnected (\(reason))") }
        }
        mic.onFailure = { [weak self] message in
            Task { @MainActor in self?.noteCaptureEvent("Microphone unavailable: \(message)") }
        }
        try await mic.start(sink: gate)
        micStall.start(now: CACurrentMediaTime())
    }

    /// Start system audio into `gate`: the process tap when it is available, else the ScreenCaptureKit
    /// path verbatim. Both backends report an unexpected stop the same way, and both are recovered
    /// (not finalized) by `recoverSystemCapture`.
    private func startSystem(into gate: CaptureGate) async throws {
        if !startProcessTap(into: gate) {
            system.onStreamStopped = { [weak self] in
                Task { @MainActor in self?.handleSystemStreamStopped() }
            }
            try await system.start(sink: gate)
        }
        systemStall.start(now: CACurrentMediaTime())
    }

    /// Start system audio on the Core Audio process tap — the screen-independent backend that hears
    /// every process regardless of window, display, output device, volume, or mute.
    ///
    /// Returns false (caller falls back to the verified ScreenCaptureKit path) when the toggle is
    /// off, the OS predates the tap API, or the tap itself can't be created. Screen recording no
    /// longer forces the fallback: the recorder owns its own video-only stream, so the tap — which
    /// hears every process regardless of window, display, volume or mute — stays the audio backend.
    private func startProcessTap(into receiver: any SampleReceiver) -> Bool {
        guard useProcessTap else { return false }
        guard #available(macOS 14.2, *) else { return false }
        let tap = AudioCaptureProcessTap()
        tap.onStreamStopped = { [weak self] in
            Task { @MainActor in self?.handleSystemStreamStopped() }
        }
        tap.onRestart = { [weak self] reason in
            Task { @MainActor in self?.noteCaptureEvent("System audio reconnected (\(reason))") }
        }
        do {
            try tap.start(sink: receiver)
            processTap = tap
            return true
        } catch {
            NSLog("[SystemAudio] process tap unavailable — using ScreenCaptureKit: \(error.localizedDescription)")
            return false
        }
    }

    /// Create + run the streaming transcriber with a FIXED language. Returns false when the engine
    /// isn't ready. The update closure (and everything downstream) is unchanged from before.
    @discardableResult
    private func attachStreamer(language: String?) -> Bool {
        guard let streamer = engine.makeStreamer(language: language, promptTokens: sessionPromptTokens, onUpdate: { [weak self] live in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.displaySegments = live.confirmed
                self.hypothesisText = live.hypothesis
                self.transcript = live.text
            }
        }) else { return false }
        self.streamer = streamer
        streamTask = Task { await streamer.run() }
        return true
    }

    /// "Auto" language (Feature B): wait for ~3 s of lead-in audio, detect the language ONCE, pin it
    /// for the whole session (streaming + final pass), then attach the streamer. Falls back to
    /// English when detection fails or the recording stops first. Runs on the main actor; the heavy
    /// detection itself is inside WhisperKit (off-main).
    private func detectLanguageThenAttachStreamer() async {
        while isRecording, engine.sampleCount < 3 * 16_000 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
        }
        guard isRecording else { return }
        var lang = "en"
        do {
            let lead = engine.sink.snapshot()
            let det = try await engine.detectLanguage(samples: Array(lead.prefix(30 * 16_000)))
            lang = det.language
            sessionLanguageLabel = "Detected: \(Self.languageName(lang))"
        } catch {
            NSLog("[Lang] auto-detect failed (\(error)); falling back to English")
            sessionLanguageLabel = "English (detect failed)"
        }
        sessionLanguage = lang
        guard isRecording, streamer == nil else { return }
        attachStreamer(language: lang)
    }

    private func stopFlow() async {
        // `busy` was already set synchronously by stopRecording(); it stays set through the whole
        // finalize (including the full-quality pass) so no new recording can start meanwhile.
        defer { busy = false }

        // Stop the one-shot language detection (auto mode) before touching the streamer.
        detectTask?.cancel()
        await detectTask?.value
        detectTask = nil

        await teardownCaptures()

        // Grab the live (confirmed) segments before discarding the streamer, then ensure the loop
        // has fully exited (no in-flight transcribe) before the final pass — shared WhisperKit.
        let liveSegments = await streamer?.snapshotSegments() ?? []
        await streamer?.stop()
        await streamTask?.value
        streamer = nil
        streamTask = nil

        status = .finalizing

        if let dir = sessionDir {
            await finalizeDocumentSession(dir: dir, liveSegments: liveSegments)
        }

        pendingTitleSeed = nil
        autoStartedMeeting = nil
        if let message = pendingStopMessage {
            pendingStopMessage = nil
            status = .error(message)
        } else {
            status = .idle
        }
    }

    /// Finalize a session into its folder: transcript.md + session.json (+ audio.m4a, + screen.mp4
    /// when the screen was recorded). Same two-pass shape as before — immediate live save, then the
    /// full-quality re-transcription.
    private func finalizeDocumentSession(dir: URL, liveSegments: [TranscriptSegment]) async {
        let meta = sessionMeta()

        // 1) Immediate live save (interleaved, no OCR yet). Do NOT blank the on-screen transcript to
        //    confirmed-only here: `liveSegments` is the streamer's CONFIRMED segments (all-but-last-2),
        //    which can be empty on a short session even though live text was shown — blanking it would
        //    drop the window to the empty "Start recording" screen. Keep the live text until the final pass.
        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: liveSegments), to: dir)
        lastSessionDir = dir
        lastSessionHasVideo = screenResult != nil
        lastSavedURL = dir.appendingPathComponent("transcript.md")
        notifySessionSaved(dir)

        // 2) Full-quality transcript segments (+ custom-vocab bias), re-saved over the live pass.
        do {
            // Resolve the session language. nil only happens for an "auto" session stopped before the
            // lead-in detection ran — detect on whatever audio we have, falling back to English.
            if sessionLanguage == nil {
                let lead = engine.sink.snapshot()
                sessionLanguage = (try? await engine.detectLanguage(samples: Array(lead.prefix(30 * 16_000))))?.language ?? "en"
            }
            let finalSegs = try await engine.finalPassSegments(language: sessionLanguage, promptTokens: sessionPromptTokens)
            let segs = finalSegs.isEmpty ? liveSegments : finalSegs
            if !segs.isEmpty {
                transcript = segs.map { $0.text }.joined(separator: " ")
                displaySegments = segs       // clean final transcript in the review canvas
                hypothesisText = ""
            }

            // B3: persist the source audio (16 kHz mono, T0-aligned with the segment timestamps) for
            // playback in the Viewer. Off by default-respecting `saveAudioEnabled`.
            let buffer = engine.sink.snapshot()
            let duration = buffer.isEmpty ? nil : Double(buffer.count) / 16_000.0
            var audioName: String? = nil
            if saveAudioEnabled, buffer.count > 1_600 {
                audioName = (try? AudioFileIO.writeCompactAudio(buffer, to: dir.appendingPathComponent("audio.m4a")))?.lastPathComponent
            }

            // Final save with enriched meta (saved audio + screen video + live ⌥⌘B bookmarks).
            let finalMeta = sessionMeta(audioFile: audioName, durationSeconds: duration, bookmarks: sessionBookmarks)
            DocumentBuilder.writeSession(SessionDoc(meta: finalMeta, segments: segs), to: dir)

            // D3: notify when a long pass completes (silent no-op if Notifications aren't granted).
            if let duration, duration > 30 {
                Notifier.notify(title: "Transcript ready", body: "Your \(Int(duration))s session has been transcribed.")
            }
        } catch {
            NSLog("[Final] document pass failed: \(error)")
        }

        // 3) Index the finished transcript, then auto-title/tag on-device, then the OPTIONAL Stage-1
        //    post-passes (diarization labels + cleanup), all off the main thread and OFF the save path.
        //    The session above is already safely saved — if any pass fails it logs and degrades; the
        //    passes run serially so their read-modify-write of session.json can't race each other.
        notifySessionSaved(dir)
        let wantDiarize = diarizationEnabled
        let wantCleanup = cleanupEnabled
        let diarSamples: [Float] = wantDiarize ? engine.sink.snapshot() : []   // capture BEFORE a new session resets the sink
        Task.detached(priority: .utility) {
            SearchIndex.shared.index(sessionDir: dir)   // searchable immediately, before slow titling
            await SessionStore.ensureTitle(dir: dir)
            if wantDiarize { await DiarizationPass.run(dir: dir, samples: diarSamples) }
            if wantCleanup { await CleanupPass.run(dir: dir) }
        }
    }

    private func notifySessionSaved(_ dir: URL) {
        NotificationCenter.default.post(name: .transcriberSessionSaved, object: nil, userInfo: ["dir": dir])
    }

    private func teardownCaptures() async {
        stopHUDTimer()
        // Stopping from a paused state must not leak the pre-roll: that audio was captured while
        // the user had recording held, so it is discarded rather than flushed into the session.
        if isPaused {
            micGate?.close()
            systemGate?.close()
        }
        isPaused = false
        pauseReason = nil
        mic.onRestart = nil
        mic.onFailure = nil
        mic.stop()
        if #available(macOS 14.2, *), let tap = processTap as? AudioCaptureProcessTap { tap.stop() }
        processTap = nil
        await system.stop()
        // Flush the mixer AFTER both captures stop, so the buffered tail reaches the sink before the
        // final pass reads it. No-op (nil) for single-source recordings.
        mixer?.flush()
        mixer = nil
        micGate = nil
        systemGate = nil
        // Finalize the video LAST: the mixer flush above is the final audio of the session, and it
        // belongs in the video's audio track too.
        if let recorder = screenRecorder {
            screenRecorder = nil
            recorder.onPreview = nil
            recorder.onStopped = nil
            screenResult = await recorder.finish()
        }
        // A capture that died mid-session finalizes on its own task; wait for it before saving.
        await screenFinishTask?.value
        screenFinishTask = nil
        isRecordingScreen = false
        screenPreview = nil
    }

    // MARK: Live bookmarks (⌥⌘B)

    /// Drop a bookmark at the current session time (seconds of RECORDED audio from T0 — paused
    /// stretches excluded, so the marker lands where the audio actually is). No-op when not recording.
    func addBookmark() {
        guard isRecording else { return }
        let t = clock.time(now: CACurrentMediaTime())
        sessionBookmarks.append(Bookmark(time: t, label: nil))
        lastBookmarkAt = t
        // Auto-dismiss the transient confirmation after a moment.
        Task { @MainActor in try? await Task.sleep(nanoseconds: 1_500_000_000); if self.lastBookmarkAt == t { self.lastBookmarkAt = nil } }
    }

    // MARK: Import (B1 — drag-drop / Import…)

    /// Import one or more audio/video files into full sessions (off the recording path). Opens the
    /// last imported session in the Viewer. Ignored while recording or already busy.
    func importFiles(_ urls: [URL]) {
        let supported = urls.filter { Importer.isSupported($0) }
        guard !supported.isEmpty, !busy, !isRecording else { return }
        busy = true
        status = .preparingModel("Importing…")
        let langSetting = effectiveLanguageSetting
        let config = Importer.Config(model: model.rawValue,
                                     language: langSetting == "auto" ? nil : langSetting,
                                     autoDetectLanguage: langSetting == "auto",
                                     vocabulary: effectiveVocabulary,
                                     diarize: diarizationEnabled, cleanup: cleanupEnabled)
        Task {
            var failure: String?
            // Keep an .error status visible on failure; only return to .idle when everything succeeded.
            defer { busy = false; if failure == nil { status = .idle } }
            var lastDir: URL?
            for url in supported {
                do {
                    let dir = try await Importer.run(url: url, config: config) { msg in
                        Task { @MainActor in self.status = .preparingModel(msg) }
                    }
                    lastDir = dir
                    Notifier.notify(title: "Import complete", body: url.lastPathComponent)
                } catch {
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    NSLog("[Import] failed for \(url.lastPathComponent): \(error)")
                    failure = msg
                    status = .error("Import failed: \(msg)")
                }
            }
            if let lastDir { WindowManager.shared.showViewer(dir: lastDir) }
        }
    }

    /// Show an NSOpenPanel to pick file(s) to import (menu / Library "Import…").
    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = (AudioFileIO.audioExtensions.union(AudioFileIO.videoExtensions))
            .compactMap { UTType(filenameExtension: $0) }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    // MARK: Calendar-aware capture (Feature C)

    /// Create/destroy the monitor to match the toggle. When OFF, no CalendarMonitor (and therefore
    /// no EKEventStore) exists at all — the strict "zero EventKit use" invariant.
    private func updateCalendarMonitor() {
        if calendarCaptureEnabled {
            guard calendarMonitor == nil else { return }
            let m = CalendarMonitor(
                leadSeconds: { [weak self] in self?.calendarLeadSeconds ?? 60 },
                autoStart: { [weak self] in self?.calendarAutoStart ?? false },
                isRecording: { [weak self] in self?.isRecording ?? false },
                onTrigger: { [weak self] candidate, action in
                    Task { @MainActor in self?.handleMeetingTrigger(candidate, action) }
                })
            calendarMonitor = m
            m.start()
        } else {
            calendarMonitor?.stop()
            calendarMonitor = nil
            meetingPrompt = nil
        }
    }

    private func handleMeetingTrigger(_ candidate: MeetingCandidate, _ action: MeetingTriggerAction) {
        guard !isRecording, !busy else { return }   // never interrupt an in-progress recording
        switch action {
        case .prompt:
            meetingPrompt = candidate
            Notifier.notify(title: "Meeting starting",
                            body: "“\(candidate.title)” — open Said to start a bot-free recording.")
        case .autoStart:
            startMeetingRecording(candidate, auto: true)
        case .ignore:
            break
        }
    }

    /// Start a calendar-triggered recording: the configured capture source (one-shot override, the
    /// user's persisted source pick is untouched) + the meeting title seeded into the session.
    func startMeetingRecording(_ candidate: MeetingCandidate, auto: Bool = false) {
        guard !isRecording, !busy else { return }
        meetingPrompt = nil
        pendingTitleSeed = candidate.title
        sourceOverride = calendarCaptureSource
        if auto { autoStartedMeeting = candidate.title }
        startRecording()
    }

    func dismissMeetingPrompt() { meetingPrompt = nil }
    func dismissAutoStartBanner() { autoStartedMeeting = nil }

    /// Lazily request Calendar access (only ever called when the feature is enabled).
    func requestCalendarAccess() { calendarMonitor?.requestAccessIfNeeded() }

    // MARK: Live meter + timer

    private func startHUDTimer() {
        recordingStart = Date()
        hud.level = 0
        hud.elapsed = 0
        hud.silentSeconds = 0
        hud.quietSeconds = 0
        digitalSilenceSince = nil
        hudTimer?.invalidate()
        // ~12 Hz: drives the meter (RMS of recent samples) and the mm:ss timer.
        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                // While paused the sink stops growing, so its RMS would freeze at the last recorded
                // block; read the live input level from the gates instead so the meter still moves
                // (and visibly shows the audio that is about to trigger an auto-resume).
                self.hud.level = self.isPaused ? min(1, self.inputLevel() * 8) : self.engine.sink.recentRMS()
                self.hud.elapsed = Int(self.clock.time(now: now))
                self.updateSilenceWatch()
                self.updateAutoPause(now: now)
                self.updateCaptureHealth(now: now)
            }
        }
    }

    /// The loudest live input across the active capture sources, measured BEFORE the pause gate —
    /// this is what "is anyone talking / is anything playing" means, paused or not.
    private func inputLevel() -> Float {
        max(micGate?.level ?? 0, systemGate?.level ?? 0)
    }

    /// Auto-pause on silence, auto-resume on sound (both off when the setting is off). A manual
    /// pause is never auto-resumed — `SilenceMonitor` enforces that.
    private func updateAutoPause(now: TimeInterval) {
        guard isRecording, !busy else { return }
        let decision = silence.update(level: inputLevel(), now: now, paused: isPaused, reason: pauseReason)
        let quiet = Int(silence.quietSeconds(now: now))
        if hud.quietSeconds != quiet { hud.quietSeconds = quiet }
        switch decision {
        case .autoPause:
            pauseRecording(auto: true)
        case .autoResume:
            resumeRecording()
        case .none:
            break
        }
    }

    /// Watchdog: a live capture delivers buffers continuously (zero-filled when nothing plays), so
    /// "no buffers at all" means the source broke — a device switch, a stream the OS tore down, an
    /// engine that stopped. Rebuild it instead of letting the session quietly record nothing.
    private func updateCaptureHealth(now: TimeInterval) {
        guard isRecording, !busy, !recovering else { return }
        if sessionSource.usesMic, let gate = micGate,
           micStall.shouldRecover(lastDelivery: gate.lastDeliveryAt, now: now) {
            recoverMicCapture(reason: "no microphone audio for \(Int(AudioActivity.stallSeconds))s")
        }
        if sessionSource.usesSystem, let gate = systemGate,
           systemStall.shouldRecover(lastDelivery: gate.lastDeliveryAt, now: now) {
            recoverSystemCapture(reason: "no system audio for \(Int(AudioActivity.stallSeconds))s")
            return
        }

        // The failure a callback watchdog cannot see: the capture is alive and delivering, but every
        // buffer is digital silence. That is what a mid-session output-device change can leave
        // behind — and unlike a stall, the session looks perfectly healthy while recording nothing.
        // Rebuilt at most twice per session, because genuinely silent audio looks identical; after
        // that the status bar's "no system audio" warning stands on its own.
        guard sessionSource.usesSystem, !isPaused, hud.silentSeconds >= 15, silentRebuilds < 2,
              now - lastSilentRebuildAt >= 45 else { return }
        silentRebuilds += 1
        lastSilentRebuildAt = now
        digitalSilenceSince = nil          // don't re-fire on the same stretch while it restarts
        recoverSystemCapture(reason: "system audio has been silent for \(hud.silentSeconds)s")
    }

    /// Track how long the sink's tail has been all-zero. A live mic carries a noise floor, so
    /// exact zeros mean the capture is running but carrying nothing — for Mic+System the mixer
    /// sums both, so a working mic keeps this from firing when only system audio is silent.
    private func updateSilenceWatch() {
        // Paused sessions stop feeding the sink, so its tail is stale — the paused state is what
        // the UI shows then, not a "dead capture" warning.
        guard !isPaused else {
            digitalSilenceSince = nil
            if hud.silentSeconds != 0 { hud.silentSeconds = 0 }
            return
        }
        guard engine.sink.recentAllZero() else {
            digitalSilenceSince = nil
            if hud.silentSeconds != 0 { hud.silentSeconds = 0 }
            return
        }
        let since = digitalSilenceSince ?? Date()
        digitalSilenceSince = since
        let seconds = Int(Date().timeIntervalSince(since)) + 1   // +1: the all-zero window itself
        if hud.silentSeconds != seconds { hud.silentSeconds = seconds }
    }

    private func stopHUDTimer() {
        hudTimer?.invalidate()
        hudTimer = nil
        hud.level = 0
        hud.silentSeconds = 0
        hud.quietSeconds = 0
        digitalSilenceSince = nil
    }

    // MARK: AI summary (on-device)

    var summaryAvailable: Bool { Summarizer.isAvailable }

    func summarizeTranscript() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSummarizing else { return }
        showingSummary = true       // switch the window into the summary state
        isSummarizing = true
        summary = ""
        Task {
            defer { isSummarizing = false }
            do {
                summary = try await Summarizer.summarize(text)
            } catch {
                summary = "⚠︎ " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Leave the summary view, back to the transcript.
    func closeSummary() { showingSummary = false }

    /// Clear the on-screen transcript/summary/frames → back to the empty "Start transcribing" state.
    /// Does not delete any already-saved files on disk.
    func clearTranscript() {
        guard !isRecording else { return }
        transcript = ""
        displaySegments = []
        hypothesisText = ""
        summary = ""
        showingSummary = false
        screenPreview = nil
        screenResult = nil
        lastSessionDir = nil
        lastSessionHasVideo = false
        lastSavedURL = nil
    }

    // MARK: Screen recording

    /// Start a screen recording (screen + audio in one session), or stop the one in progress.
    ///
    /// This is the whole feature in one entry point: ⌥⌘S, the Record Screen button and the menu row
    /// all call it. Both settings it touches are ONE-SHOT — the screen flag and the screen-audio
    /// source apply to this session only, so pressing ⌥⌘S once never silently turns "record my screen"
    /// on forever, and never changes the user's persisted source.
    ///
    /// While a session is already running it only stops a SCREEN recording. Stopping someone's live
    /// audio session because they pressed the screen key would destroy the thing they can't redo, and
    /// a video can't be added halfway through a timeline it wasn't recording.
    func toggleScreenRecording() {
        if isRecording {
            if isRecordingScreen { stopRecording() }
            else { noteCaptureEvent("Already recording — stop this session first to record the screen") }
            return
        }
        screenOverride = true
        sourceOverride = screenAudioSource
        startRecording()
    }

    /// Refresh the live list of screen-recording targets (call when the Settings picker opens).
    func refreshTargets() {
        Task {
            let options = await ScreenRecorder.availableTargets()
            await MainActor.run { self.availableTargets = options }
        }
    }

    /// The recorded label for the current target ("Main Display", a window title, …).
    var screenTargetLabel: String {
        availableTargets.first { $0.target == screenTarget }?.label ?? {
            switch screenTarget {
            case .mainDisplay: return "Main Display"
            case .display(let id): return "Display \(id)"
            case .window: return "Window"
            case .app(let bundle): return bundle
            }
        }()
    }

    /// The capture stopped on its own (recorded window closed, display unplugged). Audio — and the
    /// transcript, which is the thing you can't re-create — keeps going; only the video ends, and
    /// whatever was recorded up to that point is still finalized and saved.
    private func handleScreenStopped(_ message: String) {
        guard isRecordingScreen else { return }
        NSLog("[ScreenRec] stopped mid-session — audio continues: \(message)")
        noteCaptureEvent("Screen recording ended — audio continues")
        isRecordingScreen = false
        screenPreview = nil
        let recorder = screenRecorder
        screenRecorder = nil
        // Held so the stop flow can await it — otherwise a stop right after the capture died could
        // save session.json before the video finished writing, orphaning the file.
        screenFinishTask = Task { @MainActor [weak self] in
            let result = await recorder?.finish()
            self?.screenResult = result
        }
    }

    /// The system-audio backend reported that it stopped. This used to end the session, which is
    /// what made an output-device change or a stream hiccup look like "it just stopped transcribing".
    /// Now it is a recoverable event: stand the capture back up and keep the session running.
    private func handleSystemStreamStopped() {
        guard isRecording else { return }
        recoverSystemCapture(reason: "system audio stream stopped")
    }

    // MARK: Capture recovery (a broken source must not end a session)

    /// Rebuild the system-audio capture in place, around whatever the audio hardware looks like NOW.
    /// The session, the sink, the streamer, and every timestamp survive untouched — only the capture
    /// object is replaced. Only after several consecutive failures (≈ the device is really gone) is
    /// the session finalized, and then with an explicit error rather than a silent stop.
    private func recoverSystemCapture(reason: String) {
        guard isRecording, !recovering, let gate = systemGate else { return }
        recovering = true
        NSLog("[Recover] system audio: \(reason)")
        noteCaptureEvent("Reconnecting system audio…")
        Task {
            defer { recovering = false }

            // Tear down whichever backend was live (both are safe to stop twice).
            if #available(macOS 14.2, *), let tap = processTap as? AudioCaptureProcessTap { tap.stop() }
            processTap = nil
            system.onStreamStopped = nil
            await system.stop()

            // Let a device transition settle before rebuilding — an immediate retry during a
            // switchover is the one most likely to fail.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard isRecording else { return }

            do {
                try await startSystem(into: gate)
                // Stop can land during the (awaiting) restart. Teardown already ran by then, so a
                // capture started here would outlive the session — undo it rather than leak it.
                guard isRecording else {
                    if #available(macOS 14.2, *), let tap = processTap as? AudioCaptureProcessTap { tap.stop() }
                    processTap = nil
                    await system.stop()
                    return
                }
                systemRecoveryFailures = 0
                noteCaptureEvent("System audio reconnected")
            } catch {
                systemRecoveryFailures += 1
                NSLog("[Recover] system audio failed (\(systemRecoveryFailures)): \(error)")
                if systemRecoveryFailures >= 4 {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    noteCaptureEvent("System audio unavailable — finishing the session")
                    // Surfaced by stopFlow once finalizing completes (it owns `status` until then),
                    // so the reason the session ended is never lost behind a plain "Idle".
                    pendingStopMessage = "System audio was lost: \(message)"
                    stopRecording()
                } else {
                    noteCaptureEvent("System audio unavailable — retrying…")
                }
            }
        }
    }

    /// Mic recovery is cheaper: `AudioCaptureMic` rebuilds itself around the new input device, so
    /// this is only the watchdog's nudge for a stall that produced no notification at all.
    private func recoverMicCapture(reason: String) {
        guard isRecording else { return }
        NSLog("[Recover] microphone: \(reason)")
        mic.forceRestart(reason: reason)
    }

    /// Surface a capture event without interrupting anything. Auto-clears so the status bar
    /// returns to its normal read.
    private func noteCaptureEvent(_ message: String) {
        captureNotice = message
        noticeClearTask?.cancel()
        noticeClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.captureNotice == message { self?.captureNotice = nil }
        }
    }

    // MARK: Pause / resume

    /// Pause and resume from one control (button, ⌥⌘P, menu). No-op when not recording.
    func togglePause() {
        guard isRecording else { return }
        if isPaused { resumeRecording() } else { pauseRecording() }
    }

    /// Stop feeding the recording without ending the session. Capture keeps running (so the level
    /// is still measured and an auto-pause can hear audio return), but its samples are dropped —
    /// the audio stays gapless and the transcript never accumulates silence.
    func pauseRecording(auto: Bool = false) {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pauseReason = auto ? .silence : .manual
        clock.pause(now: CACurrentMediaTime())
        micGate?.close()
        systemGate?.close()
        screenRecorder?.setPaused(true, totalPaused: clock.totalPaused(now: CACurrentMediaTime()))
        status = .paused
        hud.level = 0
        NSLog("[Pause] paused (\(auto ? "auto — silence" : "manual"))")
    }

    /// Resume recording.
    ///
    /// Pre-roll is replayed ONLY when the app paused itself: then the withheld second contains the
    /// audio that triggered the resume, and dropping it would clip the first word. After a pause the
    /// USER asked for, nothing captured during it is ever recorded — the app must not put audio into
    /// a session that the user had deliberately stopped.
    func resumeRecording() {
        guard isRecording, isPaused else { return }
        let now = CACurrentMediaTime()
        let replayPreroll = (pauseReason == .silence)
        clock.resume(now: now)
        micGate?.open(flushPreroll: replayPreroll)
        systemGate?.open(flushPreroll: replayPreroll)
        screenRecorder?.setPaused(false, totalPaused: clock.totalPaused(now: now))
        isPaused = false
        pauseReason = nil
        status = .recording
        silence.reset()
        hud.quietSeconds = 0
        NSLog("[Pause] resumed")
    }

    private func resetPauseState() {
        isPaused = false
        pauseReason = nil
        captureNotice = nil
        noticeClearTask?.cancel()
        noticeClearTask = nil
        recovering = false
        systemRecoveryFailures = 0
        silentRebuilds = 0
        lastSilentRebuildAt = 0
        silence = SilenceMonitor(enabled: autoPauseEnabled, pauseAfter: autoPauseSeconds)
        micStall = StallMonitor()
        systemStall = StallMonitor()
        hud.quietSeconds = 0
    }

    private func sessionMeta(audioFile: String? = nil, durationSeconds: Double? = nil,
                             bookmarks: [Bookmark] = []) -> SessionMeta {
        SessionMeta(date: sessionStartDate,
                    sourceLabel: sessionSource.label,
                    modelName: model.rawValue,
                    targetLabel: screenResult != nil ? screenTargetLabel : nil,
                    modeLabel: screenResult != nil ? screenQuality.shortLabel : nil,
                    // Calendar-triggered sessions seed the meeting title (kept by ensureTitle; tags
                    // still backfill lazily). language stored only when non-default, so a default
                    // English session.json stays byte-identical.
                    title: pendingTitleSeed,
                    audioFile: audioFile, durationSeconds: durationSeconds, bookmarks: bookmarks,
                    language: (sessionLanguage != nil && sessionLanguage != "en") ? sessionLanguage : nil,
                    videoFile: screenResult?.url.lastPathComponent,
                    videoWidth: screenResult?.width, videoHeight: screenResult?.height)
    }

    // MARK: Export (single-file HTML / PDF of the last session)

    func exportHTML() {
        guard let dir = lastSessionDir, let out = savePanel(suggested: dir.lastPathComponent, ext: "html") else { return }
        do {
            try Exporter.exportHTML(sessionDir: dir, to: out)
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } catch {
            NSLog("[Export] HTML failed: \(error)")
        }
    }

    func exportPDF() {
        guard let dir = lastSessionDir, let out = savePanel(suggested: dir.lastPathComponent, ext: "pdf") else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                try await Exporter.exportPDF(sessionDir: dir, to: out)
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } catch {
                NSLog("[Export] PDF failed: \(error)")
            }
        }
    }

    private func savePanel(suggested: String, ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggested).\(ext)"
        panel.allowedContentTypes = [ext == "pdf" ? UTType.pdf : UTType.html]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Errors / permissions

    private func handle(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        status = .error(message)
        NSLog("[Said] start failed: \(message)")

        switch error {
        case CaptureError.micDenied:
            WindowManager.shared.presentPermissionAlert(
                title: "Microphone Access Needed",
                message: message,
                settingsAnchor: "Privacy_Microphone"
            )
        case CaptureError.screenRecordingNeedsGrant:
            WindowManager.shared.presentPermissionAlert(
                title: "Screen Recording Needed",
                message: message,
                settingsAnchor: "Privacy_ScreenCapture"
            )
        default:
            break
        }
    }

    // MARK: Saving

    /// ~/Desktop/Transcripts — where saved transcripts live.
    nonisolated static var transcriptsDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    /// Reveal the transcripts folder in Finder (creating it if needed).
    func openTranscriptsFolder() {
        let dir = Self.transcriptsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
