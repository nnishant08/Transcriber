import Foundation
import AVFoundation
import Combine
import SwiftUI
import SaidKit

/// Drives one session view: the transcript, its frames, playback, and the summary/task tabs.
///
/// Playback is ONE timeline over two engines, exactly as on the Mac: `AVPlayer` when the session
/// carries a video (a Mac screen recording, or an imported video), `AVAudioPlayer` otherwise. Every
/// seek entry point — a line, a bookmark, a frame, a citation — goes through `goTo`, so both behave
/// identically and the `[mm:ss]` anchors stay sacred across platforms.
@MainActor
final class SessionModel: ObservableObject {

    let dir: URL
    @Published private(set) var meta: SessionMeta
    @Published private(set) var segments: [TranscriptSegment]
    @Published private(set) var frames: [FrameEvent] = []

    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published var isScrubbing = false
    @Published private(set) var hasVideo = false
    @Published var scrollTarget: String?

    // Figures (the figures wave). Same sidecar, same rules as the Mac; see `SessionFigures.swift`
    // in the Mac target for the identical logic on the other side.
    @Published private(set) var figures: [Figure] = []
    @Published private(set) var figuresByRow: [Int: [ResolvedFigure]] = [:]
    @Published private(set) var figuresDropped = 0
    @Published private(set) var figuresLabelled = true
    @Published private(set) var isExtractingFigures = false
    /// Set when the last extraction was skipped for heat (§9): the tab offers a re-run.
    @Published private(set) var figuresSkippedForHeat = false

    private var audio: AVAudioPlayer?
    private(set) var video: AVPlayer?
    private var ticker: Timer?
    private var tempFiles: [URL] = []

    init(dir: URL) {
        self.dir = dir
        let doc = DocumentBuilder.readSession(dir)
        self.meta = doc?.meta ?? SessionStore.synthMeta(dir: dir)
        var segs = doc?.segments ?? []
        if segs.isEmpty { segs = SessionStore.timedSegments(dir: dir) }   // legacy → derive from [mm:ss]
        self.segments = segs
        // The video-XOR-frames invariant is resolved ONCE, by SessionDoc.visual.
        if case .frames(let f) = doc?.visual { self.frames = f.sorted { $0.time < $1.time } }
        setUpPlayback(doc: doc)
        reloadFigures()
        extractFiguresIfNeeded()
    }

    // MARK: Figures

    var figuresEnabled: Bool { FigureStore.isEnabled }

    func reloadFigures() {
        guard FigureStore.isEnabled else { figures = []; figuresByRow = [:]; figuresDropped = 0; return }
        let doc = SessionDoc(meta: meta, segments: segments, frames: frames)
        let state = FigureStore.read(dir: dir, doc: doc)
        figures = state.sidecar?.figures ?? []
        figuresLabelled = state.sidecar?.labelled ?? true
        // The phone shows the edited view when edits exist, exactly as the Mac defaults to it.
        let displayed = EditStore.editedSegments(dir: dir, segments: segments)
        let r = FigureOverlay.resolve(figures, in: displayed)
        figuresDropped = r.dropped
        var byRow: [Int: [ResolvedFigure]] = [:]
        for f in r.resolved { byRow[f.figure.segmentIndex, default: []].append(f) }
        figuresByRow = byRow
    }

    func figures(forRow i: Int) -> [ResolvedFigure] { figuresByRow[i] ?? [] }

    var railFigures: [ResolvedFigure] {
        figuresByRow.values.flatMap { $0 }.sorted { $0.figure.start < $1.figure.start }
    }

    var figuresNeedRerun: Bool {
        guard FigureStore.isEnabled, !isExtractingFigures else { return false }
        return figuresSkippedForHeat || figuresDropped > 0 || !figuresLabelled
            || FigurePass.needsExtraction(dir: dir, doc: SessionDoc(meta: meta, segments: segments, frames: frames))
    }

    func extractFiguresIfNeeded() {
        guard FigureStore.isEnabled, !isExtractingFigures,
              FigurePass.needsExtraction(dir: dir, doc: SessionDoc(meta: meta, segments: segments, frames: frames))
        else { return }
        extractFigures()
    }

    /// The re-run affordance. Respects the thermal gate (§9): at `.serious` labelling is skipped,
    /// at `.critical` nothing runs and the session stays unextracted rather than half-extracted.
    func extractFigures() {
        guard FigureStore.isEnabled, !isExtractingFigures else { return }
        let mode: FigurePass.Mode
        switch ProcessInfo.processInfo.thermalState {
        case .critical: figuresSkippedForHeat = true; return
        case .serious: mode = .detectOnly
        default: mode = .full
        }
        figuresSkippedForHeat = false
        isExtractingFigures = true
        let dir = self.dir
        Task.detached(priority: .utility) {
            _ = await FigurePass.run(dir: dir, mode: mode)
            await MainActor.run { [weak self] in
                self?.isExtractingFigures = false
                self?.reloadFigures()
            }
        }
    }

    // MARK: The header (Workstream R)

    enum Status: Equatable {
        case working(String), ready
        var word: String { if case .working(let w) = self { return w }; return "Ready" }
    }

    /// The phone has no live finalize state to read once a session is open: the recording screen
    /// owns that until it hands the folder over. What CAN still be running is this model's own
    /// figure extraction, which is what the status reports.
    var status: Status { isExtractingFigures ? .working("Finding figures") : .ready }

    /// Rename in place — `meta.title` only, on a fresh read, plus the transcript file rename the
    /// Mac's `ensureTitle` makes when a title lands.
    func renameTitle(to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != meta.title, var doc = DocumentBuilder.readSession(dir) else { return }
        doc.meta.title = title
        DocumentBuilder.writeSessionJSON(doc, to: dir)
        SessionPaths.renameTranscript(in: dir, toMatch: doc.meta)
        meta = doc.meta
        SearchIndex.shared.index(sessionDir: dir)
        SessionStore.postSessionSaved(dir)
    }

    deinit {
        ticker?.invalidate()
        for f in tempFiles { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: Playback

    private func setUpPlayback(doc: SessionDoc?) {
        duration = meta.durationSeconds ?? 0

        if case .video(let name) = doc?.visual, let url = playableURL(dir.appendingPathComponent(name)) {
            let item = AVPlayerItem(url: url)
            video = AVPlayer(playerItem: item)
            video?.actionAtItemEnd = .pause
            hasVideo = true
            Task { [weak self] in
                if let d = try? await item.asset.load(.duration) {
                    await MainActor.run { self?.duration = max(self?.duration ?? 0, d.seconds) }
                }
            }
            return
        }
        guard let name = meta.audioFile,
              let url = playableURL(dir.appendingPathComponent(name)),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.prepareToPlay()
        audio = player
        if duration <= 0 { duration = player.duration }
    }

    /// An encrypted artifact cannot be handed to AVFoundation, so decrypt it to a temp file and play
    /// that. Plaintext — the default — returns the original URL with no copy.
    private func playableURL(_ url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let head = try? FileHandle(forReadingFrom: url).read(upToCount: 8),
              SessionIO.isEncryptedBlob(head) else { return url }
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let plain = SessionIO.decryptIfNeeded(raw)
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("said-\(UUID().uuidString).\(ext)")
        guard (try? plain.write(to: tmp)) != nil else { return nil }
        tempFiles.append(tmp)
        return tmp
    }

    var hasPlayback: Bool { audio != nil || video != nil }

    func togglePlay() {
        guard hasPlayback else { return }
        isPlaying ? pause() : play()
    }

    func play() {
        // The session was recording under `.record`; playback needs `.playback`, and the category
        // must go back afterwards rather than being held while idle.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        video?.play(); audio?.play()
        isPlaying = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncTime() }
        }
    }

    func pause() {
        video?.pause(); audio?.pause()
        isPlaying = false
        ticker?.invalidate(); ticker = nil
    }

    private func syncTime() {
        guard !isScrubbing else { return }
        if let video { currentTime = video.currentTime().seconds }
        else if let audio {
            currentTime = audio.currentTime
            if !audio.isPlaying { isPlaying = false; ticker?.invalidate(); ticker = nil }
        }
        scrollTarget = rowID(at: currentTime)
    }

    /// THE single seek entry point. Lines, bookmarks, frames and citations all come through here.
    func goTo(_ t: TimeInterval) {
        let upper = duration > 0 ? duration : max(0, t)
        let clamped = min(max(0, t), upper)
        currentTime = clamped
        video?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        audio?.currentTime = clamped
        scrollTarget = rowID(at: clamped)
    }

    func skip(_ delta: TimeInterval) { goTo(currentTime + delta) }

    // MARK: Merged timeline

    enum Row: Identifiable {
        case segment(index: Int, seg: TranscriptSegment)
        case frame(FrameEvent)

        var id: String {
            switch self {
            case .segment(let i, _): return "seg-\(i)"
            case .frame(let f):      return "frame-\(f.imagePath)"
            }
        }
        var time: TimeInterval {
            switch self {
            case .segment(_, let s): return s.start
            case .frame(let f):      return f.time
            }
        }
    }

    /// Segments and frames merged by time, matching the order `DocumentBuilder.markdown` writes:
    /// on a tie, text before frame.
    var rows: [Row] {
        var out: [(TimeInterval, Int, Row)] = []
        for (i, s) in segments.enumerated() { out.append((s.start, 0, .segment(index: i, seg: s))) }
        for f in frames { out.append((f.time, 1, .frame(f))) }
        out.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return out.map(\.2)
    }

    private func rowID(at t: TimeInterval) -> String? {
        let all = rows
        if let r = all.last(where: { $0.time <= t }) { return r.id }
        return all.first?.id
    }

    func isActive(_ row: Row) -> Bool { rowID(at: currentTime) == row.id }

    func frameImage(_ f: FrameEvent) -> UIImage? {
        guard let data = try? SessionIO.readData(dir.appendingPathComponent(f.imagePath)) else { return nil }
        return UIImage(data: data)
    }

    func speakerName(_ slot: Int) -> String { meta.speakerLabel(slot) }

    // MARK: Rename a speaker

    /// Persist a per-session rename, writing ONLY the fields this screen owns — the post-save passes
    /// (title, diarization, cleanup) may be updating the same file, and a whole-document write would
    /// clobber them.
    func rename(slot: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var doc = DocumentBuilder.readSession(dir) else { return }
        var names = doc.meta.speakerNames ?? [:]
        if trimmed.isEmpty { names.removeValue(forKey: String(slot)) } else { names[String(slot)] = trimmed }
        doc.meta.speakerNames = names.isEmpty ? nil : names
        // Re-render the transcript so the new name is searchable, exactly as the Mac does.
        DocumentBuilder.writeSession(doc, to: dir)
        meta = doc.meta
        SearchIndex.shared.index(sessionDir: dir)
        SessionStore.postSessionSaved(dir)
    }
}
