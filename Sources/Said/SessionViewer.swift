import SaidKit
import SwiftUI
import AppKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers

// MARK: - Viewer model

/// Drives one Session Viewer window: the loaded session, playback (the screen recording when there
/// is one, else the audio), the summary suite (styles / action items / chapters, cached in
/// session.json), and the grounded chat panel.
@MainActor
final class SessionViewerModel: ObservableObject {
    let dir: URL
    @Published var meta: SessionMeta
    @Published var segments: [TranscriptSegment]
    /// Still frames on the timeline (Phase 2). Non-empty ONLY for sessions that arrived from an
    /// iPhone in a `.said` bundle — the Mac renders frames but never captures them.
    @Published var frames: [FrameEvent] = []

    // Playback — ONE timeline with two possible engines. A session with a screen recording plays the
    // video (which already carries the same audio); otherwise the saved audio file plays alone. Every
    // seek entry point (transcript line, bookmark, chapter, chat citation) goes through `goTo`, so
    // both engines behave identically to the rest of the Viewer.
    private var player: AVAudioPlayer?
    private(set) var videoPlayer: AVPlayer?
    private var playTimer: Timer?
    @Published var hasAudio = false
    @Published var hasVideo = false
    /// The video pane can be collapsed — some sessions are read, not watched.
    @Published var videoVisible = true
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isScrubbing = false         // true while the user drags the slider
    @Published var scrollTarget: String?       // segment id the transcript should scroll to

    // Summary suite
    @Published var summaryStyle: SummaryStyle
    /// Non-nil when a CUSTOM summary mode is selected instead of a built-in style (Feature D2).
    @Published var selectedCustomMode: CustomSummaryMode? = nil
    @Published var summaryText: String = ""
    @Published var isSummarizing = false
    @Published var actionItems: [String]
    @Published var chapters: [Chapter]
    @Published var isGeneratingExtras = false

    // Cleanup view (Feature D1) — default Verbatim (trust first); Cleaned is opt-in per window.
    @Published var showCleaned = false

    // MARK: Editing (Phase 3, Wave 3)

    /// The user's corrections. An OVERLAY — `transcript.md` on disk is never touched.
    @Published var edits: [TranscriptEdit] = []
    /// Showing the Edited view. Distinct from `isEditing`: you can read the edited transcript
    /// without being in edit mode.
    @Published var showEdited = false
    /// Edit mode: words become individually selectable and correctable.
    @Published var isEditing = false
    /// `segments` with the overlay applied, recomputed only when the edits change — the transcript
    /// re-renders on every scroll tick and applying the overlay per frame would be wasteful.
    @Published private(set) var editedSegments: [TranscriptSegment] = []
    /// One-shot notice when a correction crosses the learning threshold, e.g.
    /// "Said will listen for *anastomosis* from now on."
    @Published var learnedNotice: String?
    /// Set when an edit invalidates cached summaries. Shown as an affordance rather than silently
    /// re-running expensive generation (§6.3).
    @Published var summariesAreStale = false
    /// Edits that no longer anchor — after a re-transcription reshaped the segments. Kept in the
    /// file, never deleted (§6.5); this is what tells the user.
    @Published var unanchoredEditCount = 0

    /// The window's `UndoManager`, handed in by the view.
    ///
    /// Deliberately the window's rather than a private stack, so ⌘Z / ⇧⌘Z behave exactly as they do
    /// everywhere else on the Mac and edits sit in the same undo history as the rest of the session
    /// (§6.3). `weak` because the window owns it, not the model.
    weak var undoManager: UndoManager?

    var hasEdits: Bool { !edits.isEmpty }
    /// Editing is offered in Verbatim and Edited only. Cleaned and Redacted are DERIVED views, and
    /// an edit made against a derived text has no unambiguous home in the verbatim record (§6.3).
    var canEdit: Bool { !showCleaned && !showRedacted }

    /// Re-read the session from disk, discarding nothing the user is holding.
    ///
    /// Used after a re-transcription replaces the transcript. Deliberately re-reads rather than
    /// mutating in place: the pass on disk is authoritative, and half-updating an in-memory model
    /// to match it is how the two drift apart.
    func reload() {
        guard let doc = DocumentBuilder.readSession(dir) else { return }
        meta = doc.meta
        segments = doc.segments
        frames = doc.frames
        refreshEditedSegments()
        objectWillChange.send()
    }

    /// The segment as currently displayed, honouring the Edited view.
    func visibleSegment(at index: Int) -> TranscriptSegment {
        guard showEdited, editedSegments.indices.contains(index) else {
            return segments.indices.contains(index) ? segments[index] : TranscriptSegment(start: 0, end: 0, text: "")
        }
        return editedSegments[index]
    }

    // Chat
    @Published var chat: [ChatTurn] = []
    @Published var chatInput: String = ""
    @Published var isAnswering = false

    var bookmarks: [Bookmark] { meta.bookmarks }
    var fmAvailable: Bool { Intelligence.isAvailable }
    var fmMessage: String? { Intelligence.availabilityMessage() }
    /// True when there is something to play at all (video or audio) — drives the player bar.
    var hasPlayback: Bool { hasVideo || hasAudio }
    var hasCleaned: Bool { segments.contains { $0.cleanedText != nil } }
    var hasSpeakers: Bool { segments.contains { $0.speaker != nil } }
    var customModes: [CustomSummaryMode] { AppModel.shared.customSummaryModes }

    /// Display text for one segment under the current view toggle. The `[mm:ss]` anchor (seg.start)
    /// is identical in every view, so click-to-seek works in all of them. Redacted takes precedence
    /// (privacy-first) when active; then Cleaned; else verbatim.
    func displayText(_ seg: TranscriptSegment) -> String {
        if showRedacted { return seg.redactedText ?? seg.text }
        return showCleaned ? (seg.cleanedText ?? seg.text) : seg.text
    }

    /// Display text for the row at `index`. Goes through `visibleSegment` so the Edited view shows
    /// the overlay; every other view is exactly as before.
    func displayText(at index: Int) -> String { displayText(visibleSegment(at: index)) }

    func speakerName(_ slot: Int) -> String { meta.speakerLabel(slot) }

    /// One row of the transcript column: a spoken segment or a slide frame.
    enum TimelineRow: Identifiable {
        case segment(index: Int, seg: TranscriptSegment)
        case frame(FrameEvent)

        var id: String {
            switch self {
            case .segment(let i, _):  return "seg-\(i)"
            case .frame(let f):       return "frame-\(f.imagePath)"
            }
        }
        var time: TimeInterval {
            switch self {
            case .segment(_, let s):  return s.start
            case .frame(let f):       return f.time
            }
        }
    }

    /// Segments and frames merged by time, matching the order `DocumentBuilder.markdown` writes:
    /// on a tie, text before frame. Recomputed rather than stored, because `segments` can change
    /// (speaker rename re-renders) and a stale merge would silently reorder the transcript.
    var timelineRows: [TimelineRow] {
        var rows: [(TimeInterval, Int, TimelineRow)] = []
        for (i, s) in segments.enumerated() { rows.append((s.start, 0, .segment(index: i, seg: s))) }
        for f in frames { rows.append((f.time, 1, .frame(f))) }
        rows.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return rows.map(\.2)
    }

    /// PNG bytes for a frame, read through `SessionIO` so an encrypted session still displays.
    func frameImage(_ f: FrameEvent) -> CGImage? {
        guard let data = try? SessionIO.readData(dir.appendingPathComponent(f.imagePath)),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    init(dir: URL) {
        self.dir = dir
        let doc = DocumentBuilder.readSession(dir)
        self.meta = doc?.meta ?? SessionStore.synthMeta(dir: dir)
        var segs = doc?.segments ?? []
        if segs.isEmpty { segs = SessionStore.timedSegments(dir: dir) }   // legacy → derive from [mm:ss]
        self.segments = segs
        self.summaryStyle = AppModel.shared.defaultSummaryStyle
        self.actionItems = doc?.meta.actionItems ?? []
        self.chapters = doc?.meta.chapters ?? []
        // The video-XOR-frames invariant (Phase 2, §P3) is resolved ONCE here, by SessionDoc.visual,
        // so nothing below ever has to reconcile two visual timelines against one clock.
        if case .frames(let f) = doc?.visual { self.frames = f.sorted { $0.time < $1.time } }
        if let cached = self.meta.summaries[summaryStyle.rawValue] { self.summaryText = cached }
        setupVideo()
        if !hasVideo { setupAudio() }   // the video already carries the session's audio
    }

    deinit {
        playTimer?.invalidate()
        player?.stop()
        videoPlayer?.pause()
        for t in tempMediaURLs { try? FileManager.default.removeItem(at: t) }
    }

    // MARK: Playback

    /// Temp decrypted media backing playback when the session is encrypted (cleaned up on deinit).
    private var tempMediaURLs: [URL] = []

    /// An encrypted artifact can't be handed to AVFoundation, so decrypt it to a temp file and play
    /// that. Plaintext (the default) returns the original URL — no copy, no behavior change.
    private func playableURL(_ url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let head = try? FileHandle(forReadingFrom: url).read(upToCount: 8),
              SessionIO.isEncryptedBlob(head) else { return url }
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let plain = SessionIO.decryptIfNeeded(raw)
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("said-\(UUID().uuidString).\(ext)")
        guard (try? plain.write(to: tmp)) != nil else { return nil }
        tempMediaURLs.append(tmp)
        return tmp
    }

    private func setupVideo() {
        guard let name = meta.videoFile, let url = playableURL(dir.appendingPathComponent(name)) else { return }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        videoPlayer = p
        hasVideo = true
        duration = meta.durationSeconds ?? 0
        // The asset's own duration is authoritative (and only known asynchronously).
        Task { @MainActor [weak self] in
            if let d = try? await item.asset.load(.duration) {
                let seconds = CMTimeGetSeconds(d)
                if seconds.isFinite, seconds > 0 { self?.duration = seconds }
            }
        }
    }

    private func setupAudio() {
        guard let name = meta.audioFile, let url = playableURL(dir.appendingPathComponent(name)) else { return }
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.prepareToPlay()
        player = p
        hasAudio = true
        duration = p.duration > 0 ? p.duration : (meta.durationSeconds ?? 0)
    }

    func togglePlay() {
        if let videoPlayer {
            if isPlaying { videoPlayer.pause(); isPlaying = false; stopTick() }
            else { videoPlayer.play(); isPlaying = true; startTick() }
            return
        }
        guard let player else { return }
        if player.isPlaying { player.pause(); isPlaying = false; stopTick() }
        else { player.play(); isPlaying = true; startTick() }
    }

    /// Jump to a moment: seek whatever is playing, highlight, and scroll the transcript there.
    func goTo(_ t: TimeInterval) {
        let upper = duration > 0 ? duration : max(0, t)
        let clamped = min(max(0, t), upper)
        currentTime = clamped
        if let videoPlayer {
            videoPlayer.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
        } else if let player {
            player.currentTime = clamped
        }
        scrollTarget = activeSegmentID(at: clamped)
    }

    private func startTick() {
        stopTick()
        playTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let video = self.videoPlayer {
                    if !self.isScrubbing { self.currentTime = CMTimeGetSeconds(video.currentTime()) }
                    if video.timeControlStatus == .paused { self.isPlaying = false; self.stopTick() }
                    return
                }
                guard let player = self.player else { return }
                if !self.isScrubbing { self.currentTime = player.currentTime }   // don't fight a drag
                if !player.isPlaying { self.isPlaying = false; self.stopTick() }
            }
        }
    }
    private func stopTick() { playTimer?.invalidate(); playTimer = nil }

    var activeIndex: Int? {
        segments.firstIndex { currentTime >= $0.start && currentTime < $0.end }
            ?? segments.lastIndex { $0.start <= currentTime }
    }
    /// The transcript row a seek should scroll to.
    ///
    /// Resolved against the MERGED timeline, not just segments, so seeking to a frame's timestamp —
    /// by clicking the frame, an AI citation, or a search hit on its OCR text — scrolls to the frame
    /// card rather than to the speech line before it. On a tie the frame wins, matching the merge
    /// order (text before frame) so the last row at that instant is the frame.
    private func activeSegmentID(at t: TimeInterval) -> String? {
        let rows = timelineRows
        if let row = rows.last(where: { $0.time <= t }) { return row.id }
        return rows.first?.id
    }

    // MARK: Summary suite (cached in session.json)

    /// Cache key for the current selection: built-in styles keep their raw values (unchanged);
    /// custom modes are namespaced "custom:<name>" so they can never collide.
    private var summaryCacheKey: String { selectedCustomMode?.cacheKey ?? summaryStyle.rawValue }

    func selectStyle(_ s: SummaryStyle) {
        summaryStyle = s
        selectedCustomMode = nil
        summaryText = meta.summaries[s.rawValue] ?? ""
        if summaryText.isEmpty { generateSummary() }
    }

    func selectCustomMode(_ mode: CustomSummaryMode) {
        selectedCustomMode = mode
        summaryText = meta.summaries[mode.cacheKey] ?? ""
        if summaryText.isEmpty { generateSummary() }
    }

    /// The transcript text fed to summaries: the cleaned form when the user is actively viewing
    /// Cleaned (documented choice — summaries match what's on screen), else verbatim.
    private func summarySourceText() -> String {
        if showCleaned, hasCleaned {
            return segments.map { ($0.cleanedText ?? $0.text).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        return SessionStore.transcriptPlainText(dir: dir)
    }

    func generateSummary(force: Bool = false) {
        let key = summaryCacheKey
        if !force, let cached = meta.summaries[key], !cached.isEmpty { summaryText = cached; return }
        guard fmAvailable else { summaryText = "⚠︎ " + (fmMessage ?? "Apple Intelligence is unavailable."); return }
        // Empty custom template ⇒ documented no-op (no model call).
        if let mode = selectedCustomMode,
           mode.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summaryText = "⚠︎ " + (SummaryError.emptyTemplate.errorDescription ?? "Empty template.")
            return
        }
        isSummarizing = true; summaryText = ""
        let style = summaryStyle
        let custom = selectedCustomMode
        let source = summarySourceText()
        Task {
            defer { isSummarizing = false }
            do {
                let text: String
                if let custom {
                    text = try await Intelligence.summarizeCustom(transcript: source, mode: custom)
                } else {
                    text = try await Intelligence.summarize(transcript: source, style: style)
                }
                summaryText = text
                meta.summaries[key] = text
                persistMeta()
            } catch {
                summaryText = "⚠︎ " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func generateExtras() {
        guard fmAvailable, !isGeneratingExtras else { return }
        isGeneratingExtras = true
        Task {
            defer { isGeneratingExtras = false }
            let items = await Intelligence.actionItems(transcript: SessionStore.transcriptPlainText(dir: dir))
            let chaps = await Intelligence.chapters(timestamped: SessionStore.timestampedTranscript(dir: dir))
            actionItems = items
            chapters = chaps
            meta.actionItems = items
            meta.chapters = chaps
            persistMeta()
        }
    }

    private func persistMeta() {
        if var doc = DocumentBuilder.readSession(dir) {
            // Merge ONLY the fields the Viewer owns onto the freshly-read doc, so a concurrent title/tag
            // backfill (which writes title/tags) isn't clobbered — and vice-versa (last-writer-wins → loss).
            // Stage 1 extends the allow-list with speakerNames (per-session renames); custom-mode
            // summaries ride the existing `summaries` dictionary under namespaced keys.
            doc.meta.summaries = meta.summaries
            doc.meta.actionItems = meta.actionItems
            doc.meta.chapters = meta.chapters
            doc.meta.bookmarks = meta.bookmarks
            doc.meta.speakerNames = meta.speakerNames
            // Stage 2: the Viewer also owns generated artifacts (Feature A) + the retention-keep flag
            // (Feature C1); merged here so a concurrent backfill never clobbers them and vice-versa.
            doc.meta.generatedArtifacts = meta.generatedArtifacts
            doc.meta.retentionLocked = meta.retentionLocked
            DocumentBuilder.writeSessionJSON(doc, to: dir)
        } else {
            // No readable session.json (corrupt/missing): write a fresh one but do NOT persist DERIVED
            // segments as authoritative (1 s-granularity from [mm:ss]) — keep on-the-fly derivation.
            DocumentBuilder.writeSessionJSON(SessionDoc(meta: meta, segments: []), to: dir)
        }
        SessionStore.postSessionSaved(dir)
    }

    // MARK: Speaker rename (Feature A)

    /// Rename a diarized speaker slot for THIS session. Persists via the owned-fields merge above,
    /// then re-renders `transcript.md` (labels only — verbatim text + [mm:ss] anchors unchanged) so
    /// the new name is searchable, and re-indexes.
    func renameSpeaker(slot: Int, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = meta.speakerNames ?? [:]
        if name.isEmpty || name == "Speaker \(slot)" { names[String(slot)] = nil } else { names[String(slot)] = name }
        meta.speakerNames = names.isEmpty ? nil : names
        persistMeta()
        // Re-render the on-disk markdown with the renamed labels (only meaningful for diarized
        // sessions, whose transcript.md was builder-rendered with labels in the first place).
        if var doc = DocumentBuilder.readSession(dir), doc.segments.contains(where: { $0.speaker != nil }) {
            doc.meta.speakerNames = meta.speakerNames
            DocumentBuilder.writeSession(doc, to: dir)
            Task.detached { SearchIndex.shared.index(sessionDir: self.dir) }
        }
        objectWillChange.send()   // chips resolve names via meta — refresh the visible transcript
    }

    // MARK: Chat (A1)

    func sendChat() {
        let q = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAnswering else { return }
        chat.append(ChatTurn(role: .user, text: q))
        chatInput = ""
        isAnswering = true
        let history = chat
        Task {
            defer { isAnswering = false }
            let answer = await Intelligence.answerForSession(dir: dir, question: q, history: history)
            chat.append(ChatTurn(role: .assistant, text: answer))
        }
    }

    // MARK: Generation Studio (Feature A)

    @Published var studioTemplateID: String = ""
    @Published var studioText: String = ""
    @Published var studioFormat: String = "text"
    @Published var studioJSON: String? = nil
    @Published var isGeneratingStudio = false

    var studioTemplates: [GenerationTemplate] { GenerationStudio.allTemplates(customModes: customModes) }
    var selectedStudioTemplate: GenerationTemplate? { studioTemplates.first { $0.id == studioTemplateID } }

    /// The timestamped transcript fed to generators: cleaned form when the Viewer is showing Cleaned
    /// (documented choice), else the verbatim timestamped transcript.
    private func studioSourceText() -> String {
        if showCleaned, hasCleaned {
            return segments.map { "[\(DocumentBuilder.timestamp($0.start))] " + ($0.cleanedText ?? $0.text) }
                .joined(separator: "\n")
        }
        return SessionStore.timestampedTranscript(dir: dir, maxChars: 100_000)
    }

    /// Select a Studio template, loading any cached artifact (no model call on cache hit).
    func selectStudioTemplate(id: String) {
        studioTemplateID = id
        guard let t = selectedStudioTemplate else { studioText = ""; studioJSON = nil; return }
        if t.usesSummaryCache, let cached = meta.summaries[t.cacheKey], !cached.isEmpty {
            studioText = cached; studioFormat = "text"; studioJSON = nil
        } else if let art = meta.generatedArtifacts?[t.id] {
            studioText = GenerationStudio.displayText(art); studioFormat = art.format
            studioJSON = art.format == "json" ? art.content : nil
        } else {
            studioText = ""; studioJSON = nil
        }
    }

    func runStudio(force: Bool = false) {
        guard let t = selectedStudioTemplate, !isGeneratingStudio else { return }
        if !force {
            if t.usesSummaryCache, let c = meta.summaries[t.cacheKey], !c.isEmpty { studioText = c; return }
            if let art = meta.generatedArtifacts?[t.id] { studioText = GenerationStudio.displayText(art); studioJSON = art.format == "json" ? art.content : nil; return }
        }
        guard fmAvailable else { studioText = "⚠︎ " + (fmMessage ?? "Apple Intelligence is unavailable."); return }
        isGeneratingStudio = true; studioText = ""; studioJSON = nil
        let source = studioSourceText()
        Task {
            defer { isGeneratingStudio = false }
            do {
                let out = try await GenerationStudio.generate(template: t, sourceText: source)
                studioText = out.text; studioFormat = out.format; studioJSON = out.json
                if t.usesSummaryCache {
                    meta.summaries[t.cacheKey] = out.text
                } else {
                    let content = out.format == "json" ? (out.json ?? out.text) : out.text
                    var arts = meta.generatedArtifacts ?? [:]
                    arts[t.id] = GeneratedArtifact(templateId: t.id, format: out.format, content: content, createdAt: Date())
                    meta.generatedArtifacts = arts
                }
                persistMeta()
            } catch {
                studioText = "⚠︎ " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Export the current Studio output. Flashcards/quiz get portable CSV (and Markdown for cards);
    /// everything else exports as plain `.txt` / `.md`.
    func exportStudio() {
        guard let t = selectedStudioTemplate, !studioText.isEmpty else { return }
        let base = (meta.title?.isEmpty == false ? meta.title! : dir.lastPathComponent) + " — " + t.name
        if studioFormat == "json", let json = studioJSON {
            if t.id == "flashcards", let csv = GenerationStudio.flashcardsCSV(fromJSON: json) {
                savePanel(ext: "csv", suggested: base) { url in try? Data(csv.utf8).write(to: url) }
                return
            }
            if t.id == "quiz", let csv = GenerationStudio.quizCSV(fromJSON: json) {
                savePanel(ext: "csv", suggested: base) { url in try? Data(csv.utf8).write(to: url) }
                return
            }
        }
        savePanel(ext: "md", suggested: base) { [studioText] url in try? Data(studioText.utf8).write(to: url) }
    }

    func copyStudio() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(studioText, forType: .string)
    }
    func shareStudio() { Sharing.presentShareSheet(items: [studioText]) }

    // MARK: Redaction view (Feature C2) + retention (Feature C1)

    @Published var showRedacted = false
    @Published var isRedacting = false
    var hasRedacted: Bool { segments.contains { $0.redactedText != nil } }
    var retentionLocked: Bool { meta.retentionLocked ?? false }

    /// Toggle the per-session keep flag (exempts it from the retention auto-delete sweep).
    func toggleRetentionLock() {
        meta.retentionLocked = !(meta.retentionLocked ?? false)
        persistMeta()
        objectWillChange.send()
    }

    /// Run the on-device redaction pass over this session (off the save path); refresh segments.
    func redactNow() {
        guard !isRedacting else { return }
        isRedacting = true
        Task {
            defer { isRedacting = false }
            await RedactionPass.run(dir: dir)
            if let doc = DocumentBuilder.readSession(dir) { segments = doc.segments; meta = doc.meta }
            if hasRedacted { showRedacted = true }
            objectWillChange.send()
        }
    }

    // MARK: Export / share

    func exportSubtitle(vtt: Bool) {
        let content = vtt ? Subtitles.vtt(dir: dir) : Subtitles.srt(dir: dir)
        guard let content else { presentAlert("No timing available", "This session has no per-segment timestamps to build subtitles from."); return }
        savePanel(ext: vtt ? "vtt" : "srt") { url in try Data(content.utf8).write(to: url) }
    }
    func exportText() { savePanel(ext: "txt") { [dir] url in _ = try Exporter.exportTXT(sessionDir: dir, to: url) } }
    func exportRTF() { savePanel(ext: "rtf") { [dir] url in _ = try Exporter.exportRTF(sessionDir: dir, to: url) } }
    func exportHTML() { savePanel(ext: "html") { [dir] url in _ = try Exporter.exportHTML(sessionDir: dir, to: url) } }
    func exportPDF() {
        savePanel(ext: "pdf") { [dir] url in
            // The only async exporter (WKWebView renders the PDF), so it reports its own failure.
            Task { @MainActor [weak self] in
                do { _ = try await Exporter.exportPDF(sessionDir: dir, to: url) }
                catch { self?.presentAlert("Export failed", error.localizedDescription) }
            }
        }
    }
    func share() {
        Sharing.presentShareSheet(items: [Exporter.plainText(for: dir)])
    }

    /// Export the WHOLE session as a single `.said` bundle — transcript, session.json, audio, video,
    /// images. Unlike the other exports (which are views OF the session), this is the session
    /// itself, and it keeps `SessionMeta.id` so the receiving device can tell a re-import from a new
    /// one. Encrypted sessions are decrypted into the bundle so it opens on the other device.
    /// - Parameter includingVoiceprints: opt-in, DEFAULT OFF. See `SessionBundle.write` for why the
    ///   default is safe by construction; the confirmation the user sees before this is set to true
    ///   is in `SessionViewer`'s Export menu.
    func exportBundle(includingVoiceprints: Bool = false) {
        savePanel(ext: SessionBundle.fileExtension) { [dir] url in
            _ = try SessionBundle.write(sessionDir: dir, to: url,
                                        includingVoiceprints: includingVoiceprints)
        }
    }

    /// True when this session has named speakers whose voice profiles COULD be shared — i.e. when
    /// offering the opt-in is meaningful at all.
    var canShareVoiceprints: Bool {
        guard VoiceprintStore.isEnabled, let names = meta.speakerNames, !names.isEmpty else { return false }
        let stored = Set(VoiceprintStore.all().map { $0.name.lowercased() })
        return names.values.contains { stored.contains($0.lowercased()) }
    }

    // Redacted export (Feature C2) — built from the redacted segments, never from transcript.md.
    private var redactedSegments: [TranscriptSegment] {
        segments.map { var s = $0; s.text = $0.redactedText ?? $0.text; return s }
    }
    func exportRedactedText() {
        let base = (meta.title?.isEmpty == false ? meta.title! : dir.lastPathComponent) + " — redacted"
        let body = redactedSegments.map { "[\(DocumentBuilder.timestamp($0.start))] \($0.text)" }.joined(separator: "\n")
        savePanel(ext: "txt", suggested: base) { url in try? Data(body.utf8).write(to: url) }
    }
    func exportRedactedSubtitle(vtt: Bool) {
        let segs = redactedSegments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !segs.isEmpty else { presentAlert("No timing available", "This session has no per-segment timestamps."); return }
        let content = vtt ? Subtitles.vtt(segments: segs) : Subtitles.srt(segments: segs)
        let base = (meta.title?.isEmpty == false ? meta.title! : dir.lastPathComponent) + " — redacted"
        savePanel(ext: vtt ? "vtt" : "srt", suggested: base) { url in try? Data(content.utf8).write(to: url) }
    }
    func sendToObsidian() {
        let path = AppModel.shared.obsidianVaultPath
        guard !path.isEmpty else {
            presentAlert("No Obsidian vault set", "Choose your vault folder in Settings → Sharing first."); return
        }
        do {
            let out = try Sharing.writeToObsidian(dir: dir, vaultFolder: URL(fileURLWithPath: path))
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } catch { presentAlert("Couldn't write to vault", error.localizedDescription) }
    }
    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([dir]) }

    /// Runs the save panel and reports a failure instead of swallowing it — an export that silently
    /// does nothing is indistinguishable from one that worked.
    private func savePanel(ext: String, suggested: String? = nil, write: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        let base = suggested ?? (meta.title?.isEmpty == false ? meta.title! : dir.lastPathComponent)
        panel.nameFieldStringValue = Sharing.exportFilename(base) + "." + ext
        if let ut = UTType(filenameExtension: ext) { panel.allowedContentTypes = [ut] }
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do { try write(url) }
            catch { presentAlert("Export failed", error.localizedDescription) }
        }
    }
    private func presentAlert(_ title: String, _ message: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = message; a.runModal()
    }
}

// MARK: - Viewer view

struct SessionViewer: View {
    /// Owned by `ShellModel` (the session sidebar and the shell drive the same instance), so this is
    /// observed rather than created here.
    @ObservedObject var lib: SessionViewerModel
    @State private var panel = 0   // 0 = Summary, 1 = Studio, 2 = Chat
    /// The window's undo manager, handed to the model so ⌘Z on a correction behaves like ⌘Z
    /// anywhere else rather than driving a private stack (Phase 3, §6.3).
    @Environment(\.undoManager) private var undoManager
    @State private var showRetranscribe = false
    @State private var confirmVoiceprintExport = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            HStack(spacing: 0) {
                transcriptColumn
                    .frame(maxWidth: .infinity)
                Divider().overlay(Theme.hairline)
                sidePanel.frame(width: 380)
            }
            if lib.hasPlayback {
                Divider().overlay(Theme.hairline)
                playerBar.frame(height: 52).background(Theme.titlebar)
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .onAppear {
            lib.undoManager = undoManager
            lib.reloadEdits()
        }
        .onChange(of: undoManager) { _, new in lib.undoManager = new }
        .sheet(isPresented: $showRetranscribe) { RetranscribeSheet(lib: lib) }
        .confirmationDialog("Include voice profiles?", isPresented: $confirmVoiceprintExport) {
            Button("Include voice profiles", role: .destructive) {
                lib.exportBundle(includingVoiceprints: true)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Whoever opens this file will be able to recognise these speakers in their own "
                 + "recordings. Voice profiles are biometric data — only share them with someone the "
                 + "speakers would be comfortable identifying them.")
        }
        .background(Theme.windowBG)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .environment(\.openURL, OpenURLAction { url in
            // trseek:<seconds> is an OPAQUE URL (no //), so host/path are empty — parse the body directly.
            if url.scheme == "trseek" {
                let body = url.absoluteString.replacingOccurrences(of: "trseek:", with: "")
                if let s = Double(body) { lib.goTo(s); return .handled }
            }
            return .systemAction
        })
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            // Back to the list this session was opened from (v3 screen 02's leading chevron).
            ToolbarIcon(system: "chevron.left") { ShellModel.shared.closeSession() }
                .help("Back to the Library (⌘[)")
            VStack(alignment: .leading, spacing: 4) {
                Text(lib.meta.title?.isEmpty == false ? lib.meta.title! : "Transcript")
                    .font(Theme.ui(15, weight: .semibold)).lineLimit(1)
                HStack(spacing: 7) {
                    Text(Self.dateFmt.string(from: lib.meta.date)).font(Theme.mono(11)).foregroundStyle(Theme.text3)
                    Dot(); Text(lib.meta.sourceLabel).font(Theme.ui(11.5)).foregroundStyle(Theme.text3)
                    if lib.hasVideo {
                        Dot()
                        Label(videoLabel, systemImage: "play.rectangle").font(Theme.ui(11)).foregroundStyle(Theme.accentText)
                    }
                    if lib.hasAudio { Dot(); Label("audio", systemImage: "speaker.wave.2").font(Theme.ui(11)).foregroundStyle(Theme.accentText) }
                    if let n = lib.meta.speakerCount, n > 1 { Dot(); Label("\(n) speakers", systemImage: "person.2").font(Theme.ui(11)).foregroundStyle(Theme.accentText) }
                    if let lang = lib.meta.language { Dot(); Text(AppModel.languageName(lang)).font(Theme.ui(11)).foregroundStyle(Theme.text3) }
                }
                if !lib.meta.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(lib.meta.tags.prefix(6), id: \.self) { tag in
                            Text(tag).font(Theme.ui(10.5)).foregroundStyle(Theme.text2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                    }
                }
            }
            Spacer()
            if lib.hasVideo {
                ToolbarIcon(system: lib.videoVisible ? "rectangle.topthird.inset.filled" : "rectangle") {
                    withAnimation(.easeInOut(duration: 0.18)) { lib.videoVisible.toggle() }
                }
                .help(lib.videoVisible ? "Hide the video" : "Show the video")
            }
            OnDeviceBadge()
            exportMenu
            ToolbarIcon(system: "folder") { lib.revealInFinder() }.help("Reveal in Finder")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Theme.titlebar)
    }

    /// "1080p" when we know the encoded size, else a plain label.
    private var videoLabel: String {
        if let h = lib.meta.videoHeight, h > 0 { return "\(h)p" }
        return "video"
    }

    private var exportMenu: some View {
        Menu {
            Button("Subtitles (.srt)") { lib.exportSubtitle(vtt: false) }
            Button("Subtitles (.vtt)") { lib.exportSubtitle(vtt: true) }
            Divider()
            Button("Plain text (.txt)") { lib.exportText() }
            Button("Rich text (.rtf)") { lib.exportRTF() }
            Button("Web page (.html)") { lib.exportHTML() }
            Button("PDF (.pdf)") { lib.exportPDF() }
            if lib.hasRedacted {
                Divider()
                Button("Redacted text (.txt)") { lib.exportRedactedText() }
                Button("Redacted subtitles (.srt)") { lib.exportRedactedSubtitle(vtt: false) }
                Button("Redacted subtitles (.vtt)") { lib.exportRedactedSubtitle(vtt: true) }
            }
            Divider()
            Button("Send session… (.said)") { lib.exportBundle() }
            if lib.canShareVoiceprints {
                Button("Send session with voice profiles… (.said)") { confirmVoiceprintExport = true }
            }
            Divider()
            Button("Re-transcribe…") { showRetranscribe = true }
            Divider()
            Button("Share…") { lib.share() }
            Button("Send to Obsidian vault") { lib.sendToObsidian() }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up").font(Theme.ui(12.5))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: Transcript column

    /// View-mode selection ↔ the model's bool toggles.
    /// 0 = Verbatim, 1 = Edited, 2 = Cleaned, 3 = Redacted — ordered by how far each is from the
    /// recording, so the leftmost is always the thing that was actually said.
    private var viewMode: Binding<Int> {
        Binding(get: { lib.showRedacted ? 3 : (lib.showCleaned ? 2 : (lib.showEdited ? 1 : 0)) },
                set: {
                    lib.showRedacted = ($0 == 3)
                    lib.showCleaned = ($0 == 2)
                    lib.showEdited = ($0 == 1)
                    // Editing a derived view has no unambiguous home in the verbatim record, so
                    // leaving Verbatim/Edited leaves edit mode too.
                    if !lib.canEdit { lib.isEditing = false }
                })
    }

    /// The transcript toolbar: Verbatim/Cleaned/Redacted switch (when those views exist), plus the
    /// privacy controls — Redact (run the on-device pass) and a per-session retention Keep toggle.
    private var transcriptToolbar: some View {
        HStack(spacing: 10) {
            if lib.hasCleaned || lib.hasRedacted || lib.hasEdits {
                Picker("", selection: viewMode) {
                    Text("Verbatim").tag(0)
                    if lib.hasEdits { Text("Edited").tag(1) }
                    if lib.hasCleaned { Text("Cleaned").tag(2) }
                    if lib.hasRedacted { Text("Redacted").tag(3) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            TranscriptEditControls(lib: lib)
            if lib.showRedacted {
                Text("PII/PHI masked — best-effort, review before sharing. Saved transcript stays verbatim.")
                    .font(Theme.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
            } else if lib.showCleaned {
                Text("Fillers removed, punctuation fixed. Saved transcript stays verbatim.")
                    .font(Theme.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer()
            if !lib.hasRedacted {
                Button { lib.redactNow() } label: {
                    if lib.isRedacting { ProgressView().controlSize(.mini) }
                    else { Label("Redact", systemImage: "eye.slash").font(Theme.ui(11.5)) }
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accentText)
                .help("Mask names, emails, phone numbers, etc. — on-device, non-destructive")
                .disabled(lib.isRedacting || lib.segments.isEmpty)
            }
            Button { lib.toggleRetentionLock() } label: {
                Label(lib.retentionLocked ? "Kept" : "Keep",
                      systemImage: lib.retentionLocked ? "lock.fill" : "lock.open")
                    .font(Theme.ui(11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(lib.retentionLocked ? Theme.accentText : Theme.text3)
            .help("Exempt this session from auto-delete (retention policy)")
        }
        .padding(.horizontal, 20).padding(.vertical, 7)
    }

    /// The screen recording, above the transcript it belongs to. Deliberately NOT a separate window:
    /// the point of recording the screen here is that the video and the words are one document —
    /// clicking a line moves the video, and the video moving highlights the line.
    @ViewBuilder private var videoPane: some View {
        if lib.hasVideo, lib.videoVisible, let player = lib.videoPlayer {
            VideoPlayer(player: player)
                .frame(height: 300)
                .background(Color.black)
                .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
        }
    }

    private var transcriptColumn: some View {
        VStack(spacing: 0) {
            videoPane
            transcriptToolbar
            if lib.hasCleaned || lib.hasRedacted || lib.hasEdits { Divider().overlay(Theme.hairline) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // "This might be Alice — confirm?" A match is a PROPOSAL, never an
                        // assignment (§7.4); this bar is the whole user-facing surface of that rule.
                        VoiceprintProposalBar(lib: lib)
                        if !lib.chapters.isEmpty { chaptersStrip }
                        ForEach(lib.timelineRows) { row in
                            switch row {
                            case .segment(let i, _):
                                let seg = lib.visibleSegment(at: i)
                                TranscriptLine(index: i, seg: seg,
                                               text: lib.displayText(at: i),
                                               editing: lib.isEditing && lib.canEdit,
                                               onEditWord: { wordIndex, original, corrected in
                                                   lib.commitEdit(segmentIndex: i, wordIndex: wordIndex,
                                                                  original: original, corrected: corrected)
                                               },
                                               speaker: seg.speaker.map { (lib.speakerName($0), Theme.speakerColor($0)) },
                                               active: lib.activeIndex == i,
                                               bookmarked: isBookmarked(seg),
                                               onTap: { lib.goTo(seg.start) },
                                               onRename: seg.speaker.map { slot in
                                                   { (name: String) in lib.renameSpeaker(slot: slot, to: name) }
                                               })
                                    .id("seg-\(i)")
                            case .frame(let f):
                                // Click-to-seek goes through the SAME `goTo` as lines, bookmarks,
                                // chapters and AI citations. No second seek path (Phase 2, §S).
                                FrameCard(frame: f, image: lib.frameImage(f)) { lib.goTo(f.time) }
                                    .id(row.id)
                            }
                        }
                        if lib.segments.isEmpty {
                            Text("No transcript text.").font(Theme.ui(13)).foregroundStyle(Theme.text3).padding(24)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                }
                .onChange(of: lib.scrollTarget) { _, target in
                    if let target { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) } }
                }
            }
        }
    }

    private var chaptersStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("CHAPTERS").font(Theme.ui(10.5, weight: .medium)).tracking(1.2).foregroundStyle(Theme.text3)
            FlowChips(items: lib.chapters.map { ($0.id, DocumentBuilder.timestamp($0.start) + "  " + $0.title) }) { id in
                if let c = lib.chapters.first(where: { $0.id == id }) { lib.goTo(c.start) }
            }
        }
        .padding(.bottom, 14)
    }

    private func isBookmarked(_ seg: TranscriptSegment) -> Bool {
        lib.bookmarks.contains { $0.time >= seg.start && $0.time < seg.end }
    }

    // MARK: Side panel (Summary / Chat)

    private var sidePanel: some View {
        VStack(spacing: 0) {
            Picker("", selection: $panel) {
                Text("Summary").tag(0); Text("Studio").tag(1); Text("Chat").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(10)
            Divider().overlay(Theme.hairline)
            switch panel {
            case 0: summaryPanel
            case 1: studioPanel
            default: ChatPanel(lib: lib)
            }
        }
        .background(Theme.surface.opacity(0.4))
    }

    // MARK: Generation Studio panel (Feature A)

    private var studioPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("GENERATION STUDIO").font(Theme.ui(10.5, weight: .medium)).tracking(1.2).foregroundStyle(Theme.text3)

                Picker("Template", selection: Binding(get: { lib.studioTemplateID },
                                                      set: { lib.selectStudioTemplate(id: $0) })) {
                    Text("Choose a template…").tag("")
                    ForEach(GenerationGroup.allCases, id: \.self) { group in
                        let items = lib.studioTemplates.filter { $0.group == group }
                        if !items.isEmpty {
                            Section(group.rawValue) {
                                ForEach(items) { Text($0.name).tag($0.id) }
                            }
                        }
                    }
                }.labelsHidden()

                if !lib.fmAvailable {
                    Text(lib.fmMessage ?? "Apple Intelligence is unavailable.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.text3)
                } else if lib.studioTemplateID.isEmpty {
                    Text("Pick a template to turn this session into structured notes, study materials, or creator outputs — all on-device.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.text3)
                } else if lib.isGeneratingStudio {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Generating on-device…").font(Theme.ui(13)).foregroundStyle(Theme.text2) }
                } else if lib.studioText.isEmpty {
                    GhostButton(system: "sparkles", title: "Generate \(lib.selectedStudioTemplate?.name ?? "")") { lib.runStudio() }
                } else {
                    SummaryBody(text: lib.studioText)
                    HStack(spacing: 8) {
                        GhostButton(system: "arrow.clockwise", title: "Regenerate") { lib.runStudio(force: true) }
                        GhostButton(system: "doc.on.doc", title: "Copy") { lib.copyStudio() }
                    }
                    HStack(spacing: 8) {
                        GhostButton(system: "square.and.arrow.up", title: exportLabel) { lib.exportStudio() }
                        GhostButton(system: "paperplane", title: "Share") { lib.shareStudio() }
                    }
                }
            }
            .padding(14)
        }
    }

    private var exportLabel: String {
        let id = lib.selectedStudioTemplate?.id
        return (id == "flashcards" || id == "quiz") ? "Export CSV" : "Export"
    }

    /// Unified selection key: built-in raw values, or "custom:<name>" for user modes (Feature D2).
    private var styleSelection: Binding<String> {
        Binding(get: { lib.selectedCustomMode?.cacheKey ?? lib.summaryStyle.rawValue },
                set: { key in
                    if let mode = lib.customModes.first(where: { $0.cacheKey == key }) {
                        lib.selectCustomMode(mode)
                    } else if let style = SummaryStyle(rawValue: key) {
                        lib.selectStyle(style)
                    }
                })
    }

    private var summaryPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if lib.customModes.isEmpty {
                    // No custom modes (the shipped default) — the segmented control, unchanged.
                    Picker("Style", selection: Binding(get: { lib.summaryStyle }, set: { lib.selectStyle($0) })) {
                        ForEach(SummaryStyle.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                } else {
                    // Built-ins stay first-class; the user's custom modes follow in one picker.
                    Picker("Style", selection: styleSelection) {
                        ForEach(SummaryStyle.allCases) { Text($0.label).tag($0.rawValue) }
                        Divider()
                        ForEach(lib.customModes) { m in Text(m.name).tag(m.cacheKey) }
                    }.labelsHidden()
                }

                if !lib.fmAvailable {
                    Text(lib.fmMessage ?? "Apple Intelligence is unavailable.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.text3)
                } else if lib.isSummarizing {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Summarizing on-device…").font(Theme.ui(13)).foregroundStyle(Theme.text2) }
                } else if lib.summaryText.isEmpty {
                    GhostButton(system: "sparkles", title: "Generate \(lib.selectedCustomMode?.name ?? lib.summaryStyle.label)") { lib.generateSummary() }
                } else {
                    SummaryBody(text: lib.summaryText)
                    HStack(spacing: 8) {
                        GhostButton(system: "arrow.clockwise", title: "Regenerate") { lib.generateSummary(force: true) }
                        GhostButton(system: "doc.on.doc", title: "Copy") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lib.summaryText, forType: .string)
                        }
                    }
                }

                Divider().overlay(Theme.hairline)

                // Action items + chapters (generated together).
                HStack {
                    Text("ACTION ITEMS").font(Theme.ui(10.5, weight: .medium)).tracking(1.2).foregroundStyle(Theme.text3)
                    Spacer()
                    if lib.fmAvailable {
                        Button { lib.generateExtras() } label: {
                            if lib.isGeneratingExtras { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "wand.and.stars").font(.system(size: 12)) }
                        }.buttonStyle(.plain).foregroundStyle(Theme.accent).help("Extract action items + chapters")
                    }
                }
                if lib.actionItems.isEmpty {
                    Text(lib.fmAvailable ? "Tap the wand to extract action items and chapters." : "Unavailable without Apple Intelligence.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.text3)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(lib.actionItems.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "square").font(.system(size: 12)).foregroundStyle(Theme.text3).padding(.top, 2)
                                Text(item).font(Theme.ui(12.5)).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                }

                if !lib.bookmarks.isEmpty {
                    Divider().overlay(Theme.hairline)
                    Text("BOOKMARKS").font(Theme.ui(10.5, weight: .medium)).tracking(1.2).foregroundStyle(Theme.text3)
                    FlowChips(items: lib.bookmarks.map { ($0.id, DocumentBuilder.timestamp($0.time)) }) { id in
                        if let b = lib.bookmarks.first(where: { $0.id == id }) { lib.goTo(b.time) }
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: Player bar

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button { lib.togglePlay() } label: {
                Image(systemName: lib.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16))
                    .frame(width: 30, height: 30)
            }.buttonStyle(.plain).foregroundStyle(Theme.text)
            Text(timeStr(lib.currentTime)).font(Theme.mono(11)).foregroundStyle(Theme.text2).frame(width: 44)
            Slider(value: Binding(get: { lib.currentTime }, set: { lib.currentTime = min(max(0, $0), max(1, lib.duration)) }),
                   in: 0...max(1, lib.duration),
                   onEditingChanged: { editing in
                       lib.isScrubbing = editing
                       if !editing { lib.goTo(lib.currentTime) }   // seek + scroll only when the drag ends
                   })
            Text(timeStr(lib.duration)).font(Theme.mono(11)).foregroundStyle(Theme.text2).frame(width: 44)
        }
        .padding(.horizontal, 16)
    }

    private func timeStr(_ t: TimeInterval) -> String {
        let s = Int(max(0, t)); return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd  HH:mm"; return f
    }()
}

// MARK: - Subviews

/// A slide frame on the transcript timeline (Phase 2).
///
/// Render only — there is no way to produce one of these on a Mac. A frame is here because the
/// session arrived from an iPhone in a `.said` bundle.
///
/// Styled as a sticker card on the current Theme tokens: solid surface, generous radius, a hard
/// offset edge in the rule colour rather than a soft blur. The timestamp is amber-on-amber-tint,
/// because amber marks position on the timeline.
private struct FrameCard: View {
    let frame: FrameEvent
    let image: CGImage?
    let onTap: () -> Void

    @State private var showOCR = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                } else {
                    // The session.json knows about a frame whose file didn't survive. Say so
                    // plainly rather than rendering an empty box.
                    HStack(spacing: 7) {
                        Image(systemName: "photo").font(.system(size: 13))
                        Text("Slide image missing").font(Theme.ui(12))
                    }
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity).padding(.vertical, 26)
                    .background(Theme.surface2)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.cardRadius,
                                              bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                              topTrailingRadius: Theme.cardRadius))

            HStack(spacing: 8) {
                Text(DocumentBuilder.timestamp(frame.time))
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(Theme.okText)
                Text("SLIDE")
                    .font(Theme.mono(9.5, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(Theme.okText.opacity(0.75))
                Spacer(minLength: 0)
                if frame.text?.isEmpty == false {
                    Button { showOCR.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showOCR ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                            Text("On-slide text").font(Theme.ui(11))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.okSoft)

            if showOCR, let ocr = frame.text, !ocr.isEmpty {
                Text(ocr)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.surface2)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(hovering ? Theme.accentBorder : Theme.hairline, lineWidth: 1)
        )
        // The identity's hard offset edge — never a soft blur.
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.hairline2).offset(y: 3)
        )
        .padding(.leading, 44).padding(.trailing, 8)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .help("Jump to \(DocumentBuilder.timestamp(frame.time))")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Slide at \(DocumentBuilder.timestamp(frame.time))")
        .accessibilityHint("Seeks playback to this slide")
    }
}

private struct TranscriptLine: View {
    let index: Int
    let seg: TranscriptSegment
    let text: String                        // verbatim / edited / cleaned / redacted, per the toggle
    /// Edit mode is on AND this view is editable (Verbatim or Edited only — Phase 3, §6.3).
    var editing: Bool = false
    /// `(wordIndex, original, corrected)`. `wordIndex` is nil for a whole-line edit.
    var onEditWord: ((Int?, String, String) -> Void)? = nil
    let speaker: (name: String, color: Color)?
    let active: Bool
    let bookmarked: Bool
    let onTap: () -> Void
    let onRename: ((String) -> Void)?       // non-nil only for diarized lines
    @State private var hover = false

    var body: some View {
        // While editing, the WORDS are the controls; wrapping them in the seek Button would swallow
        // their clicks and their keyboard focus. `allowsHitTesting` on the outer button is not
        // enough — the button is what the focus engine sees — so the wrapper is dropped entirely.
        if editing {
            content.padding(.vertical, 6).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.accentSoft : .clear))
        } else {
            Button(action: onTap) { seekableContent }
                .buttonStyle(.plain).onHover { hover = $0 }
        }
    }

    private var seekableContent: some View {
        content
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.accentSoft : (hover ? Color.primary.opacity(0.04) : .clear)))
            .contentShape(Rectangle())
    }

    private var content: some View {
        Group {
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: 3) {
                    if bookmarked { Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(Theme.accent) }
                    Text(DocumentBuilder.timestamp(seg.start)).font(Theme.mono(11)).monospacedDigit()
                        .foregroundStyle(active ? Theme.accentText : Theme.text3)
                }
                .frame(width: 58, alignment: .leading).padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    if let speaker {
                        SpeakerChip(name: speaker.name, color: speaker.color, onRename: onRename)
                    }
                    if editing, let onEditWord {
                        EditableLineBody(seg: seg, text: text, onEditWord: onEditWord, onSeek: onTap)
                    } else {
                        Text(text).font(Theme.serif).lineSpacing(5)
                            .foregroundStyle(active ? Theme.text : Theme.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// A small color-coded speaker label; clicking it opens an inline rename popover (Feature A).
private struct SpeakerChip: View {
    let name: String
    let color: Color
    let onRename: ((String) -> Void)?
    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = name
            renaming = true
        } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name).font(Theme.ui(10.5, weight: .semibold)).foregroundStyle(color)
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.13)))
        }
        .buttonStyle(.plain)
        .help("Rename this speaker (applies to the whole session)")
        .popover(isPresented: $renaming, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rename speaker").font(Theme.ui(12, weight: .semibold))
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit { commit() }
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = false }.controlSize(.small)
                    Button("Rename") { commit() }.controlSize(.small).keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }

    private func commit() {
        renaming = false
        onRename?(draft)
    }
}

private struct SummaryBody: View {
    let text: String
    var body: some View {
        let parsed = SummaryParse.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            if let err = parsed.error {
                Text(err.replacingOccurrences(of: "⚠︎ ", with: "")).font(Theme.ui(12.5)).foregroundStyle(Theme.text2)
            } else {
                if !parsed.lead.isEmpty { Text(parsed.lead).font(Theme.ui(13.5)).lineSpacing(4).foregroundStyle(Theme.text) }
                ForEach(Array(parsed.points.enumerated()), id: \.offset) { _, p in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent).padding(.top, 3)
                        Text(p).font(Theme.ui(12.5)).foregroundStyle(Theme.text2)
                    }
                }
            }
        }
    }
}

private struct ChatPanel: View {
    @ObservedObject var lib: SessionViewerModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if lib.chat.isEmpty {
                            Text(lib.fmAvailable
                                 ? "Ask anything about this session. Answers cite the [mm:ss] you can click."
                                 : (lib.fmMessage ?? "Apple Intelligence is unavailable."))
                                .font(Theme.ui(12.5)).foregroundStyle(Theme.text3).padding(.top, 6)
                            if lib.hasVideo {
                                Label("Citations jump the video, not just the transcript.",
                                      systemImage: "play.rectangle")
                                    .font(Theme.ui(11)).foregroundStyle(Theme.accentText)
                            }
                        }
                        ForEach(lib.chat) { turn in ChatBubble(turn: turn).id(turn.id) }
                        if lib.isAnswering {
                            HStack(spacing: 7) { ProgressView().controlSize(.mini); Text("Thinking…").font(Theme.ui(12)).foregroundStyle(Theme.text3) }
                        }
                        Color.clear.frame(height: 1).id("chatBottom")
                    }.padding(12)
                }
                .onChange(of: lib.chat.count) { withAnimation { proxy.scrollTo("chatBottom", anchor: .bottom) } }
            }
            Divider().overlay(Theme.hairline)
            HStack(spacing: 8) {
                TextField("Ask about this session…", text: $lib.chatInput, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.ui(13)).lineLimit(1...4)
                    .onSubmit { lib.sendChat() }
                    .disabled(!lib.fmAvailable)
                Button { lib.sendChat() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .disabled(!lib.fmAvailable || lib.chatInput.trimmingCharacters(in: .whitespaces).isEmpty || lib.isAnswering)
            }
            .padding(10)
        }
    }
}

private struct ChatBubble: View {
    let turn: ChatTurn
    var body: some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 30) }
            CitationText(turn.text)
                .font(Theme.ui(12.5)).foregroundStyle(turn.role == .user ? Theme.text : Theme.text2)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(turn.role == .user ? Theme.accentSoft : Color.primary.opacity(0.05)))
                .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
            if turn.role == .assistant { Spacer(minLength: 30) }
        }
    }
}

/// Renders text with clickable `[mm:ss]` citations (→ a `trseek:` link the Viewer intercepts to seek).
private struct CitationText: View {
    let raw: String
    init(_ raw: String) { self.raw = raw }
    var body: some View {
        Text(attributed)
    }
    private var attributed: AttributedString {
        // Replace [mm:ss] with markdown links to trseek:<seconds>. Only fall through to markdown parsing
        // when we actually substituted a citation — otherwise render the model's text verbatim so stray
        // markdown characters (e.g. file_name, *word*) aren't reinterpreted.
        var markdown = ""
        var substituted = false
        var s = Substring(raw)
        while let open = s.firstIndex(of: "[") {
            markdown += String(s[s.startIndex..<open])
            if let close = s[open...].firstIndex(of: "]") {
                let inside = String(s[s.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                if let ts = SessionStore.firstTimestamp(in: inside), ts == inside {
                    markdown += "[\(ts)](trseek:\(Int(Intelligence.secondsFromTimestamp(ts))))"
                    substituted = true
                } else {
                    markdown += String(s[open...close])
                }
                s = s[s.index(after: close)...]
            } else {
                markdown += String(s[open...]); s = s[s.endIndex...]
            }
        }
        markdown += String(s)
        guard substituted else { return AttributedString(raw) }
        if var a = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            a.foregroundColor = nil
            return a
        }
        return AttributedString(raw)
    }
}

/// A horizontally-scrolling chip row (chapters / bookmarks / tags). Simple + robust across macOS versions.
struct FlowChips: View {
    let items: [(String, String)]
    let onTap: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button { onTap(item.0) } label: {
                        Text(item.1).font(Theme.mono(10.5)).foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.accentSoft))
                            .lineLimit(1).fixedSize()
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

private struct Dot: View { var body: some View { Circle().fill(Theme.text3).frame(width: 2.5, height: 2.5) } }

// MARK: - Session sidebar (v3 screen 02: "In this session")

/// The shell's sidebar while a session is open. Every row is an anchor on the same timeline the
/// transcript, the player and the rail all share — so clicking one seeks rather than navigating away.
struct SessionSidebar: View {
    @ObservedObject var shell: ShellModel
    @ObservedObject var viewer: SessionViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { shell.closeSession() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Library").font(Theme.ui(12.5, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSidebar)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)

            Text("IN THIS SESSION").font(Theme.sectionHeader).tracking(1.0)
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 8).padding(.bottom, 2)

            row("Transcript", "waveform", count: nil, selected: true) { viewer.goTo(0) }
            row("Bookmarks", "bookmark", count: viewer.bookmarks.count, selected: false) {
                if let first = viewer.bookmarks.first { viewer.goTo(first.time) }
            }
            row("Chapters", "square.stack.3d.up", count: viewer.chapters.count, selected: false) {
                if let first = viewer.chapters.first { viewer.goTo(first.start) }
            }
            row("Screen video", "play.rectangle", count: viewer.hasVideo ? nil : 0, selected: false) {
                viewer.videoVisible = true
            }
            row("Speakers", "person.2", count: viewer.meta.speakerCount ?? 0, selected: false) {}

            Spacer(minLength: 8)
            OnDeviceBadge().padding(.top, 8)
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
    }

    @ViewBuilder
    private func row(_ label: String, _ symbol: String, count: Int?, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        let empty = (count ?? 1) == 0
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 16).opacity(selected ? 1 : 0.8)
                Text(label).font(Theme.ui(13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)").font(Theme.mono(10.5))
                        .foregroundStyle(selected ? Theme.onSelection.opacity(0.75) : Theme.text3)
                }
            }
            .foregroundStyle(selected ? Theme.onSelection : Theme.textSidebar)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(selected ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(empty ? 0.45 : 1)
        .disabled(empty)
    }
}

/// The persistent on-device / offline privacy affordance (static; no logic).
struct OnDeviceBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.laptopcomputer").font(.system(size: 10))
            Text("On-device · offline").font(Theme.ui(10.5, weight: .medium))
        }
        .foregroundStyle(Theme.ok)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Theme.ok.opacity(0.12)))
        .help("Everything stays on this Mac — no cloud, no network.")
    }
}
