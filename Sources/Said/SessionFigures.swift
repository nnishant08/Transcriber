import SwiftUI
import AppKit
import SaidKit

// MARK: - Model side (the figures wave — Workstream Q, and the header of Workstream R)

extension SessionViewerModel {

    /// Read the sidecar and resolve every figure against the text the transcript is DISPLAYING.
    /// `[]` with the feature off. A figure whose anchor no longer holds is dropped here and counted,
    /// never rendered (§P3).
    func reloadFigures() {
        guard FigureStore.isEnabled else {
            figures = []; figuresByRow = [:]; figuresDropped = 0; figuresLabelled = true
            return
        }
        let doc = SessionDoc(meta: meta, segments: segments, frames: frames)
        let state = FigureStore.read(dir: dir, doc: doc)
        let all = state.sidecar?.figures ?? []
        figures = all
        figuresLabelled = state.sidecar?.labelled ?? true
        let displayed = showEdited ? editedSegments : segments
        let r = FigureOverlay.resolve(all, in: displayed)
        figuresDropped = r.dropped
        var byRow: [Int: [ResolvedFigure]] = [:]
        for f in r.resolved { byRow[f.figure.segmentIndex, default: []].append(f) }
        figuresByRow = byRow
    }

    /// Figures safe to draw on row `i` — `[]` in the derived views (Cleaned / Redacted rewrite the
    /// words, so no anchor holds there; the rail still lists them).
    func figures(forRow i: Int) -> [ResolvedFigure] {
        guard !showCleaned, !showRedacted else { return [] }
        return figuresByRow[i] ?? []
    }

    /// Every figure that still anchors, in time order — the rail's list.
    var railFigures: [ResolvedFigure] {
        figuresByRow.values.flatMap { $0 }.sorted { $0.figure.start < $1.figure.start }
    }

    /// True when the rail should offer "Find figures" / "Run again": nothing extracted yet, a stale
    /// sidecar, a figure dropped under an edit, or a labelling run that did not finish.
    var figuresNeedRerun: Bool {
        guard FigureStore.isEnabled else { return false }
        if isExtractingFigures { return false }
        return FigurePass.needsExtraction(dir: dir, doc: SessionDoc(meta: meta, segments: segments, frames: frames))
            || figuresDropped > 0
    }

    /// Extract in the background if the session needs it (§13.1: turning the feature on extracts
    /// existing sessions on open, with no re-transcription). Idempotent while a run is in flight.
    func extractFiguresIfNeeded() {
        guard FigureStore.isEnabled, !isExtractingFigures,
              FigurePass.needsExtraction(dir: dir, doc: SessionDoc(meta: meta, segments: segments, frames: frames))
        else { reloadFigures(); return }
        extractFigures()
    }

    /// The re-run affordance. Detects again, reuses labels the model already gave, labels the rest.
    func extractFigures() {
        guard FigureStore.isEnabled, !isExtractingFigures else { return }
        isExtractingFigures = true
        let dir = self.dir
        Task.detached(priority: .utility) {
            _ = await FigurePass.run(dir: dir)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isExtractingFigures = false
                self.reloadFigures()
            }
        }
    }

    // MARK: The header (Workstream R)

    /// What the status element says, drawn from the state that already exists: the live session's
    /// `EngineStatus` when this is the session being finished, the post-save chain's report for
    /// this folder, and the Viewer's own re-transcribe / figure runs. Not a new state machine.
    enum SessionStatus: Equatable {
        case transcribing
        case working(String)
        case ready
        case failed

        var word: String {
            switch self {
            case .transcribing: return "Transcribing"
            case .working(let w): return w
            case .ready: return "Ready"
            case .failed: return "Failed"
            }
        }
    }

    func sessionStatus(app: AppModel) -> SessionStatus {
        if isRetranscribing { return .transcribing }
        if app.lastSessionDir?.path == dir.path {
            if case .finalizing = app.status { return .transcribing }
            if case .error = app.status { return .failed }
        }
        if let step = app.postSaveActivity[dir.path] { return .working(step) }
        if isExtractingFigures { return .working("Finding figures") }
        return .ready
    }

    /// Rename the session in place. Writes ONLY `meta.title` through the owned-fields merge (so a
    /// concurrent post-save pass is never clobbered), renames the transcript file to match — the
    /// same move `ensureTitle` makes when a generated title lands — and re-indexes.
    func renameTitle(to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != meta.title else { return }
        meta.title = title
        if var doc = DocumentBuilder.readSession(dir) {
            doc.meta.title = title
            DocumentBuilder.writeSessionJSON(doc, to: dir)
            SessionPaths.renameTranscript(in: dir, toMatch: doc.meta)
        }
        let dir = self.dir
        Task.detached(priority: .utility) {
            SearchIndex.shared.index(sessionDir: dir)
            SessionStore.postSessionSaved(dir)
        }
        objectWillChange.send()
    }

    /// Move this session to the Trash (never a hard delete on macOS) and leave the Viewer.
    func moveToTrash() {
        let dir = self.dir
        ShellModel.shared.closeSession()
        ShellModel.shared.library.delete([dir])
    }
}

// MARK: - Inline figures (§Q1)

/// A transcript line with its figures as real controls, laid out as wrapping runs.
///
/// Used ONLY when a line has at least one figure and is under the density ceiling; every other
/// line renders exactly as before. Plain words are `Text`; each figure is a `Button` so it is
/// clickable at rest, focusable in the tab order, and announced by VoiceOver with its label.
struct FigureLineBody: View {
    let text: String
    let figures: [ResolvedFigure]
    let active: Bool
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 5) {
            ForEach(Array(FigureRuns.split(text: text, figures: figures).enumerated()), id: \.offset) { _, run in
                switch run {
                case .word(let w):
                    Text(w).font(Theme.serif).foregroundStyle(active ? Theme.text : Theme.text2)
                case .figure(let f, let shown):
                    InlineFigure(figure: f.figure, shown: shown, active: active) { onSeek(f.figure.start) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One inline figure.
///
/// **No hue** (§Q1, §7). Violet marks a speaker and amber marks the one talking; a third colour
/// would make the transcript a puzzle. So the resting state is a low-alpha INK wash — the same
/// shape language as the search highlight, at lower contrast — plus a dotted underline, which is
/// what says "clickable" without hover. Hover and keyboard focus firm the wash and reveal the
/// label as a trailing mono annotation. No border, no pill, no chip.
struct InlineFigure: View {
    let figure: Figure
    let shown: String
    let active: Bool
    let onTap: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool

    /// The wash: ink at low alpha, firmer on hover/focus. Below the search highlight's contrast so
    /// a figure never out-shouts an active search match.
    private static let restWash = 0.07
    private static let firmWash = 0.14

    private var revealed: Bool { hover || focused }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(shown)
                    .font(Theme.serif)
                    .foregroundStyle(active ? Theme.text : Theme.text2)
                    .underline(true, pattern: .dot, color: Theme.text3)
                if revealed, let label = figure.label {
                    Text(label)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 3)
                .fill(Theme.text.opacity(revealed ? Self.firmWash : Self.restWash)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focused)
        .onHover { hover = $0 }
        .help(figure.label.map { "\($0) — \(figure.timestamp)" } ?? figure.timestamp)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Activate to play from \(figure.timestamp).")
        .animation(.easeOut(duration: 0.12), value: revealed)
    }

    private var accessibilityLabel: String {
        var s = "Figure: \(figure.raw)"
        if let l = figure.label { s += ", \(l)" }
        s += ", at \(figure.timestamp)"
        return s
    }
}

// MARK: - The rail (§Q2)

/// Every figure in time order, grouped by class, collapsible. Click seeks. This is the primary
/// surface — the inline wash is secondary to it.
struct FiguresRail: View {
    @ObservedObject var lib: SessionViewerModel
    @State private var collapsed: Set<FigureClass> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader
            Divider().overlay(Theme.hairline)
            if !FigureStore.isEnabled {
                offNote
            } else if lib.railFigures.isEmpty {
                emptyNote
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(FigureClass.allCases, id: \.self) { kind in
                            let items = lib.railFigures.filter { $0.figure.kind == kind }
                            if !items.isEmpty { group(kind, items) }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
        }
    }

    private var railHeader: some View {
        HStack(spacing: 8) {
            Text("FIGURES").font(Theme.sectionHeader).tracking(1.0).foregroundStyle(Theme.text3)
            if !lib.railFigures.isEmpty {
                Text("\(lib.railFigures.count)").font(Theme.mono(10.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
            if lib.isExtractingFigures {
                ProgressView().controlSize(.mini)
                Text("Finding…").font(Theme.ui(11)).foregroundStyle(Theme.text3)
            } else if FigureStore.isEnabled, lib.figuresNeedRerun || !lib.figuresLabelled {
                Button(lib.figures.isEmpty ? "Find figures" : "Run again") { lib.extractFigures() }
                    .controlSize(.small)
                    .help(lib.figures.isEmpty ? "Detect the numbers said in this session"
                                              : "Detect again (labels already given are kept)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var offNote: some View {
        Text("Turn on \"Find the numbers people said\" in Settings ▸ Figures to list the amounts, "
             + "percentages, counts and deadlines from this session here.")
            .font(Theme.ui(12)).foregroundStyle(Theme.text3)
            .fixedSize(horizontal: false, vertical: true).padding(14)
    }

    private var emptyNote: some View {
        Text(lib.isExtractingFigures ? "Looking for numbers…" : "No figures were said in this session.")
            .font(Theme.ui(12)).foregroundStyle(Theme.text3).padding(14)
    }

    @ViewBuilder
    private func group(_ kind: FigureClass, _ items: [ResolvedFigure]) -> some View {
        Button {
            if collapsed.contains(kind) { collapsed.remove(kind) } else { collapsed.insert(kind) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed.contains(kind) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                Text(kind.label.uppercased()).font(Theme.sectionHeader).tracking(1.0)
                Text("\(items.count)").font(Theme.mono(10))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 6).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.label), \(items.count), \(collapsed.contains(kind) ? "collapsed" : "expanded")")

        if !collapsed.contains(kind) {
            ForEach(items) { r in FigureRailRow(figure: r.figure, speaker: r.figure.speaker.map { lib.speakerName($0) },
                                                active: isActive(r.figure)) { lib.goTo(r.figure.start) } }
        }
    }

    private func isActive(_ f: Figure) -> Bool {
        lib.currentTime >= f.start && lib.currentTime < max(f.end, f.start + 1)
    }
}

/// One rail row: raw · label · timestamp · speaker. Amber only on the one being played — that is
/// the identity's one rule, and the rail follows it like every other list.
struct FigureRailRow: View {
    let figure: Figure
    let speaker: String?
    let active: Bool
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(figure.timestamp).font(Theme.mono(10.5)).monospacedDigit()
                    .foregroundStyle(active ? Theme.recordText : Theme.text3)
                    .frame(width: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(figure.raw).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    HStack(spacing: 6) {
                        if let l = figure.label {
                            Text(l).font(Theme.ui(11)).foregroundStyle(Theme.text2).lineLimit(1)
                        }
                        if let speaker {
                            if figure.label != nil { Text("·").foregroundStyle(Theme.text3) }
                            Text(speaker).font(Theme.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius)
                .fill(active ? Theme.recordSoft : (hover ? Theme.rowHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(figure.raw)\(figure.label.map { ", \($0)" } ?? ""), at \(figure.timestamp)\(speaker.map { ", \($0)" } ?? "")")
        .accessibilityHint("Activate to play from here.")
    }
}

// MARK: - The header (Workstream R)

/// One row that says what this session is. Left: the title, editable by clicking it. Right: the
/// language, the duration, and a status — a dot AND a word, because the dot alone fails for
/// anyone who cannot tell the hues apart. No actions in the row: those live in the overflow.
struct SessionHeader: View {
    @ObservedObject var lib: SessionViewerModel
    @ObservedObject var app: AppModel
    let onBack: () -> Void
    let overflow: AnyView

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ToolbarIcon(system: "chevron.left", action: onBack).help("Back to the Library (⌘[)")
            titleField
            Spacer(minLength: 12)
            rightCluster
            overflow
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Theme.titlebar)
    }

    private var displayTitle: String {
        let t = lib.meta.title?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? "Transcript" : TitleGenerator.sanitizeTitle(t)
    }

    @ViewBuilder private var titleField: some View {
        if editing {
            TextField("Title", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.ui(15, weight: .semibold))
                .focused($titleFocused)
                .onSubmit { commit() }                 // Enter commits
                .onExitCommand { editing = false }     // Escape reverts
                .onChange(of: titleFocused) { _, f in if !f, editing { commit() } }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accentBorder))
                .frame(maxWidth: 520)
                .accessibilityLabel("Session title")
        } else {
            Button {
                draft = lib.meta.title ?? ""
                editing = true
                DispatchQueue.main.async { titleFocused = true }
            } label: {
                Text(displayTitle)
                    .font(Theme.ui(15, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to rename")
            .accessibilityLabel("Session title: \(displayTitle)")
            .accessibilityHint("Activate to rename.")
        }
    }

    private func commit() {
        editing = false
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lib.renameTitle(to: t)
    }

    private var rightCluster: some View {
        HStack(spacing: 10) {
            Text(AppModel.languageName(lib.meta.language ?? "en")).font(Theme.ui(11.5)).foregroundStyle(Theme.text3)
                .lineLimit(1)
            Text("·").foregroundStyle(Theme.text3)
            Text(durationText).font(Theme.mono(11)).monospacedDigit().foregroundStyle(Theme.text3)
                .lineLimit(1)
            Text("·").foregroundStyle(Theme.text3)
            statusElement
        }
        .fixedSize()
    }

    private var durationText: String {
        let d = Int(max(0, lib.duration > 0 ? lib.duration : (lib.meta.durationSeconds ?? 0)))
        if d >= 3600 { return String(format: "%d:%02d:%02d", d / 3600, (d / 60) % 60, d % 60) }
        return String(format: "%02d:%02d", d / 60, d % 60)
    }

    /// Dot + word. The dot carries the colour, the word the meaning; neither alone is the signal.
    /// Colours are existing tokens: `ok` for Ready (the permanent-badge tone), `accent` for work in
    /// progress (violet is what AI and brand surfaces use), and the muted `pause` family for
    /// Failed — there is no red in this identity, and the word does the work.
    private var statusElement: some View {
        let status = lib.sessionStatus(app: app)
        let color: Color
        switch status {
        case .ready: color = Theme.ok
        case .transcribing, .working: color = Theme.accent
        case .failed: color = Theme.pause
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status.word).font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.text2)
                .lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.word)")
    }
}
