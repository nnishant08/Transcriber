import SwiftUI
import AppKit
import SaidKit

// MARK: - Model side

extension SessionViewerModel {

    /// Load the overlay from disk and refresh everything derived from it.
    func reloadEdits() {
        edits = EditStore.read(dir: dir)
        refreshEditedSegments()
        unanchoredEditCount = EditOverlay.unanchored(edits, in: segments).count
        // Default to the Edited view when there are edits: the user asked for those corrections,
        // and showing them the uncorrected transcript by default would be a strange greeting.
        // Verbatim stays one click away and is still what `transcript.md` holds.
        if !edits.isEmpty, !showCleaned, !showRedacted { showEdited = true }
    }

    func refreshEditedSegments() {
        editedSegments = EditOverlay.apply(segments: segments, edits: edits)
    }

    /// Commit one correction.
    ///
    /// `wordIndex` is `nil` for a whole-line edit — which is what a legacy session with no word
    /// timings gets, so every session is editable.
    func commitEdit(segmentIndex: Int, wordIndex: Int?, original: String, corrected: String) {
        let from = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, from != to else { return }

        let edit = TranscriptEdit(segmentIndex: segmentIndex, wordIndex: wordIndex,
                                  original: from, corrected: to, at: Date())
        apply(edit)

        // Undo composes with the rest of the app rather than being a bespoke stack, so ⌘Z behaves
        // the way it does everywhere else on the Mac.
        undoManager?.registerUndo(withTarget: self) { target in
            target.revert(edit)
        }
        undoManager?.setActionName("Correct “\(from)”")
    }

    private func apply(_ edit: TranscriptEdit) {
        edits.append(edit)
        persistEdits()
        // Learn only from repeats. The FIRST time someone corrects a word it is as likely to be a
        // one-off as a standing term; promoting on first sighting fills the bias list with noise and
        // degrades recognition for everything else.
        if let learned = CorrectionMemory.record(original: edit.original, corrected: edit.corrected) {
            learnedNotice = "Said will listen for “\(learned.right)” from now on."
        }
    }

    private func revert(_ edit: TranscriptEdit) {
        edits.removeAll { $0 == edit }
        persistEdits()
        undoManager?.registerUndo(withTarget: self) { target in target.apply(edit) }
        // Deliberately does NOT clear `summariesAreStale`. The summary really was generated against
        // different text, and un-marking it on undo would be a small lie that is hard to notice.
    }

    private func persistEdits() {
        // The write can fail, and the derived state is refreshed EITHER WAY. Returning early left
        // `edits` already mutated while `editedSegments`, `unanchoredEditCount` and `showEdited`
        // still described the previous state — so the correction silently did not appear, the undo
        // stack held an entry for something never displayed, and the unwritten edit would be flushed
        // to disk by the next successful one. An unsaved edit that is visible and reported is a
        // recoverable situation; an invisible one is not.
        do {
            try EditStore.write(edits, dir: dir)
            editError = nil
        } catch {
            NSLog("[Edits] could not save: \(error)")
            editError = "That correction could not be saved (\(error.localizedDescription))."
        }
        refreshEditedSegments()
        unanchoredEditCount = EditOverlay.unanchored(edits, in: segments).count
        if edits.isEmpty { showEdited = false } else if !showCleaned, !showRedacted { showEdited = true }

        // An edit changes the words, so anything derived from them is out of date. The summaries are
        // MARKED rather than regenerated: re-running generation costs real time and battery, and
        // doing it unbidden every time someone fixes a typo would be worse than a stale badge.
        if !meta.summaries.isEmpty || !(meta.generatedArtifacts?.isEmpty ?? true) {
            summariesAreStale = true
        }

        let dir = self.dir
        Task.detached(priority: .utility) {
            SearchIndex.shared.index(sessionDir: dir)
            await SemanticIndex.shared.index(sessionDir: dir)
        }
    }

    /// Discard every edit for this session.
    func clearAllEdits() {
        let previous = edits
        edits = []
        persistEdits()
        undoManager?.registerUndo(withTarget: self) { target in
            target.edits = previous
            target.persistEdits()
        }
        undoManager?.setActionName("Discard corrections")
    }
}

// MARK: - Toolbar controls

/// The edit toggle, plus the two things an edit can leave behind: a stale-summary badge and a
/// count of corrections that no longer anchor.
struct TranscriptEditControls: View {
    @ObservedObject var lib: SessionViewerModel

    var body: some View {
        if lib.canEdit {
            Button {
                lib.isEditing.toggle()
            } label: {
                Label(lib.isEditing ? "Done" : "Edit",
                      systemImage: lib.isEditing ? "checkmark" : "pencil")
                    .font(Theme.ui(12))
            }
            .buttonStyle(.borderless)
            .help(lib.isEditing
                  ? "Stop editing"
                  : "Correct a word. The saved transcript stays exactly as it was recorded.")
            .accessibilityLabel(lib.isEditing ? "Finish editing the transcript" : "Edit the transcript")
        }

        if lib.summariesAreStale {
            Label("Summaries out of date", systemImage: "clock.arrow.circlepath")
                .font(Theme.ui(10.5)).foregroundStyle(Theme.text3)
                .help("The summary and any generated documents were made before your corrections. "
                      + "Regenerate them when you want them updated.")
        }
        if lib.unanchoredEditCount > 0 {
            Label("\(lib.unanchoredEditCount) correction(s) no longer match",
                  systemImage: "exclamationmark.triangle")
                .font(Theme.ui(10.5)).foregroundStyle(.orange)
                .help("The transcript changed — most likely re-transcribed — so these corrections no "
                      + "longer line up with any words. They are kept, not deleted.")
        }
        if let problem = lib.editError {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.ui(10.5)).foregroundStyle(.red).lineLimit(1)
                .help("The correction is applied in this window but was not written to the session "
                      + "folder. Check that the folder is writable.")
                .onTapGesture { lib.editError = nil }
        }
        if let notice = lib.learnedNotice {
            Text(notice).font(Theme.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                .help("Manage learned terms in Settings ▸ Learned terms.")
                .onTapGesture { lib.learnedNotice = nil }
        }
    }
}

// MARK: - One editable word

/// A single word, selectable and correctable.
///
/// **Keyboard and VoiceOver are requirements here, not polish** (§6.3): a transcript editor that
/// only works by clicking is not finished. Each word is a real `Button`, so it takes focus in the
/// normal tab order, and its accessibility label carries the word AND how confident the engine was —
/// which is the whole reason a low-confidence word is tinted in the first place, and is otherwise
/// information available only to sighted users.
struct EditableWord: View {
    let word: WordTiming
    let onCommit: (String) -> Void
    let onSeek: () -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// Below this, the word is tinted as worth a second look. Engines report confidence on wildly
    /// different scales, so this is a display hint, never a correctness claim.
    private static let lowConfidence: Float = 0.55

    private var isUncertain: Bool {
        guard let c = word.confidence else { return false }
        return c < Self.lowConfidence
    }

    var body: some View {
        Button {
            draft = word.text
            editing = true
        } label: {
            Text(word.text)
                .font(Theme.serif)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 1)
                .background(
                    isUncertain
                        ? RoundedRectangle(cornerRadius: 3).fill(Theme.accentSoft)
                        : RoundedRectangle(cornerRadius: 3).fill(Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Activate to correct this word.")
        .popover(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Correct this word").font(Theme.ui(11)).foregroundStyle(Theme.text3)
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                    .focused($focused)
                    .onSubmit { commit() }                       // Return commits
                    .onExitCommand { editing = false }           // Escape cancels
                    .accessibilityLabel("Corrected spelling for \(word.text)")
                HStack {
                    Button("Play from here") { onSeek() }.controlSize(.small)
                    Spacer()
                    Button("Cancel") { editing = false }.controlSize(.small)
                    Button("Save") { commit() }.controlSize(.small).keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .onAppear { focused = true }
        }
    }

    private var accessibilityLabel: String {
        guard let c = word.confidence else { return word.text }
        return isUncertain
            ? "\(word.text), low confidence \(Int(c * 100)) percent"
            : "\(word.text), confidence \(Int(c * 100)) percent"
    }

    private func commit() {
        editing = false
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != word.text else { return }
        onCommit(t)
    }
}

/// A whole line rendered as editable words, or — with no word timings — as one editable line.
///
/// The legacy path is not a degraded afterthought: every session recorded before Phase 3, and every
/// session an engine transcribed without word timings, comes through here, and being able to fix a
/// line in one of them is worth more than word-level precision in a new one.
struct EditableLineBody: View {
    let seg: TranscriptSegment
    let text: String
    let onEditWord: (Int?, String, String) -> Void
    let onSeek: () -> Void

    @State private var lineDraft = ""
    @State private var editingLine = false
    @FocusState private var lineFocused: Bool

    var body: some View {
        if let words = seg.validWords {
            FlowLayout {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    EditableWord(word: word,
                                 onCommit: { corrected in onEditWord(index, word.text, corrected) },
                                 onSeek: onSeek)
                }
            }
        } else if editingLine {
            TextField("", text: $lineDraft, axis: .vertical)
                .font(Theme.serif)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...8)
                .focused($lineFocused)
                .onSubmit { commitLine() }
                .onExitCommand { editingLine = false }
                .accessibilityLabel("Corrected text for this line")
                .onAppear { lineFocused = true }
        } else {
            Button {
                lineDraft = text
                editingLine = true
            } label: {
                Text(text).font(Theme.serif).lineSpacing(5)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(text)
            .accessibilityHint("This session has no word-level timings, so the whole line is edited at once.")
        }
    }

    private func commitLine() {
        editingLine = false
        let t = lineDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != text else { return }
        onEditWord(nil, text, t)
    }
}

/// Lays words out as wrapping runs.
///
/// A real `Layout` conformance (macOS 13+, comfortably inside Said's macOS 14 floor) rather than a
/// hand-rolled `GeometryReader`: it measures each word with the same font it will be drawn in,
/// reports a correct height instead of guessing one, and — the part that matters here — leaves every
/// word a real subview, so each stays individually focusable for keyboard and VoiceOver.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + max(0, CGFloat(rows.count - 1)) * lineSpacing
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, max(widest, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        var isEmpty: Bool { indices.isEmpty }
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let advance = size.width + (row.isEmpty ? 0 : spacing)
            if !row.isEmpty, row.width + advance > width {
                rows.append(row); row = Row()
            }
            row.indices.append(i)
            row.width += row.indices.count == 1 ? size.width : advance
            row.height = max(row.height, size.height)
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }
}
