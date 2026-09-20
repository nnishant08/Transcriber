import SwiftUI
import SaidKit

// The figures wave on the iPhone (§9): same substrate, same sidecar, same rail. What differs is
// touch — there is no hover, so a tap seeks and a long-press shows the label — and a lower
// density ceiling, because the column is a third the width and the wash is the whole affordance.

// MARK: - Inline

/// A turn's text with its figures as real controls, wrapping like text.
struct FigureTurnBody: View {
    let text: String
    let figures: [ResolvedFigure]
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        WrapLayout(spacing: 4, lineSpacing: 4) {
            ForEach(Array(FigureRuns.split(text: text, figures: figures).enumerated()), id: \.offset) { _, run in
                switch run {
                case .word(let w):
                    Text(w).font(.system(size: 16, design: .serif)).foregroundStyle(Theme.text)
                case .figure(let f, let shown):
                    InlineFigureTouch(figure: f.figure, shown: shown) { onSeek(f.figure.start) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One inline figure on the phone: ink wash + dotted underline at rest (no hue — amber is the
/// current speaker, violet is a speaker). Tap seeks; long-press shows the label.
struct InlineFigureTouch: View {
    let figure: Figure
    let shown: String
    let onTap: () -> Void
    @State private var showingLabel = false

    var body: some View {
        Text(shown)
            .font(.system(size: 16, design: .serif))
            .foregroundStyle(Theme.text)
            .underline(true, pattern: .dot, color: Theme.text3)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.text.opacity(0.08)))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.35) { showingLabel = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Figure: \(figure.raw)\(figure.label.map { ", \($0)" } ?? ""), at \(MonoTime.spoken(figure.start))")
            .accessibilityHint("Double tap to play from here.")
            .accessibilityAddTraits(.isButton)
            .alert(figure.raw, isPresented: $showingLabel) {
                Button("Play from \(DocumentBuilder.timestamp(figure.start))") { onTap() }
                Button("OK", role: .cancel) { }
            } message: {
                Text(figure.label ?? "Said at \(DocumentBuilder.timestamp(figure.start))")
            }
    }
}

/// Whether a turn should draw its figures inline, by the PHONE ceiling.
func phoneWashAllowed(figureCount: Int, text: String) -> Bool {
    FigureDensity.washAllowed(figureCount: figureCount, wordCount: FigureDensity.wordCount(text),
                              ceilingPerHundredWords: FigureDensity.phoneCeilingPerHundredWords)
}

// MARK: - The rail (a tab on the phone)

struct FiguresTab: View {
    @ObservedObject var model: SessionModel
    @State private var collapsed: Set<FigureClass> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !model.figuresEnabled {
                    note("Figures are off. Turn on \"Find the numbers people said\" to list the amounts, "
                         + "percentages, counts and deadlines from this session here.")
                } else if model.isExtractingFigures {
                    HStack(spacing: 8) { ProgressView(); Text("Looking for numbers…").font(Theme.ui(13)).foregroundStyle(Theme.text2) }
                        .padding(.vertical, 8)
                } else if model.railFigures.isEmpty {
                    note(model.figuresSkippedForHeat
                         ? "Skipped while the phone was hot. Run it when things have cooled down."
                         : "No figures were said in this session.")
                    rerunButton
                } else {
                    if model.figuresNeedRerun { rerunButton }
                    ForEach(FigureClass.allCases, id: \.self) { kind in
                        let items = model.railFigures.filter { $0.figure.kind == kind }
                        if !items.isEmpty { group(kind, items) }
                    }
                }
                Color.clear.frame(height: 150)
            }
            .padding(.horizontal, 20)
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(Theme.ui(13)).foregroundStyle(Theme.text2)
            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
    }

    @ViewBuilder private var rerunButton: some View {
        if model.figuresEnabled, model.figuresNeedRerun || model.railFigures.isEmpty {
            Button { model.extractFigures() } label: {
                Text(model.figures.isEmpty ? "Find figures" : "Run again")
                    .font(Theme.ui(13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Palette.violet)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func group(_ kind: FigureClass, _ items: [ResolvedFigure]) -> some View {
        Button {
            if collapsed.contains(kind) { collapsed.remove(kind) } else { collapsed.insert(kind) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed.contains(kind) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                Text(kind.label.uppercased()).font(Theme.mono(10.5, weight: .semibold)).tracking(1.1)
                Text("\(items.count)").font(Theme.mono(10.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.text3)
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.label), \(items.count), \(collapsed.contains(kind) ? "collapsed" : "expanded")")

        if !collapsed.contains(kind) {
            ForEach(items) { r in
                FigureRow(figure: r.figure, speaker: r.figure.speaker.map { model.speakerName($0) },
                          active: model.currentTime >= r.figure.start && model.currentTime < max(r.figure.end, r.figure.start + 1)) {
                    model.goTo(r.figure.start)
                }
            }
        }
    }
}

/// A sticker row: raw, label, timestamp, speaker. Amber marks the one being played, nothing else.
private struct FigureRow: View {
    let figure: Figure
    let speaker: String?
    let active: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            MonoTime(seconds: figure.start, size: 11, weight: .medium, color: active ? Palette.amberInk2 : Theme.text3)
                .frame(width: 42, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(figure.raw).font(Theme.ui(15, weight: .semibold)).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    if let l = figure.label { Text(l).font(Theme.ui(12)).foregroundStyle(Theme.text2).lineLimit(2) }
                    if let speaker {
                        if figure.label != nil { Text("·").foregroundStyle(Theme.text3) }
                        Text(speaker).font(Theme.ui(12)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(active ? Palette.amberTint.opacity(0.5) : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.hairline2).offset(y: 3))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(figure.raw)\(figure.label.map { ", \($0)" } ?? ""), at \(MonoTime.spoken(figure.start))\(speaker.map { ", \($0)" } ?? "")")
        .accessibilityHint("Double tap to play from here")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Header (Workstream R, collapsed for the phone)

/// Title plus status on the first line; language and duration under it (§9). Tap the title to
/// rename it — the title itself is the control, not a separate pencil.
struct SessionHeaderPhone: View {
    @ObservedObject var model: SessionModel
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if editing {
                    TextField("Title", text: $draft)
                        .font(Theme.ui(24, weight: .semibold))
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { commit() }
                        .onChange(of: focused) { _, f in if !f, editing { commit() } }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
                        .accessibilityLabel("Session title")
                } else {
                    Button {
                        draft = model.meta.title ?? ""
                        editing = true
                        DispatchQueue.main.async { focused = true }
                    } label: {
                        Text(displayTitle)
                            .font(Theme.ui(27, weight: .semibold))
                            .lineLimit(2).truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Session title: \(displayTitle)")
                    .accessibilityHint("Double tap to rename.")
                }
                Spacer(minLength: 6)
                statusElement
            }
            HStack(spacing: 7) {
                if let n = model.meta.speakerCount, n > 0 {
                    HStack(spacing: -7) { ForEach(1...min(n, 3), id: \.self) { SpeakerDot(slot: $0, size: 22) } }
                }
                Text(subtitle).font(Theme.ui(13)).foregroundStyle(Theme.text2).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 14)
    }

    private var displayTitle: String {
        let raw = model.meta.title?.trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty ? TitleGenerator.fallbackTitle(transcript: "", date: model.meta.date) : raw
    }

    private var subtitle: String {
        var parts: [String] = [languageName(model.meta.language ?? "en")]
        if model.duration > 0 { parts.append(MonoTime.compact(model.duration)) }
        if let n = model.meta.speakerCount, n > 1 { parts.append("\(n) voices") }
        if !model.frames.isEmpty { parts.append("\(model.frames.count) slides") }
        if model.hasVideo { parts.append("screen recording") }
        return parts.joined(separator: " · ")
    }

    private func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    /// Dot + word, never one without the other. Ready uses the permanent-badge amber-pressed
    /// tone (`ok`), work in progress uses violet. Nothing here competes with live amber.
    private var statusElement: some View {
        let s = model.status
        return HStack(spacing: 5) {
            Circle().fill(s == .ready ? Theme.ok : Palette.violet).frame(width: 7, height: 7)
            Text(s.word).font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.text2).lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(s.word)")
    }

    private func commit() {
        editing = false
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        model.renameTitle(to: t)
    }
}

// MARK: - Wrapping layout

/// Words as wrapping runs — the same `Layout` idea as the Mac's `FlowLayout`, so each figure stays
/// a real, individually focusable view.
struct WrapLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + max(0, CGFloat(rows.count - 1)) * lineSpacing
        return CGSize(width: min(width, rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let advance = size.width + (row.indices.isEmpty ? 0 : spacing)
            if !row.indices.isEmpty, row.width + advance > width { rows.append(row); row = Row() }
            row.indices.append(i)
            row.width += row.indices.count == 1 ? size.width : advance
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
