import SaidKit
import SwiftUI
import AppKit

// MARK: - Transcript canvas (recording = live tail; idle-with-content = review)

struct TranscriptCanvas: View {
    @EnvironmentObject var model: AppModel
    let live: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(model.displaySegments.enumerated()), id: \.offset) { _, seg in
                        SegmentRow(time: seg.start, text: seg.text)
                    }
                    if live {
                        LiveTailRow(hypothesis: model.hypothesisText)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30).padding(.vertical, 26)
            }
            .onAppear { if live { scrollToBottom(proxy) } }
            .onChange(of: model.displaySegments.count) { if live { scrollToBottom(proxy) } }
            .onChange(of: model.hypothesisText) { if live { scrollToBottom(proxy) } }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

private struct SegmentRow: View {
    let time: TimeInterval
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(DocumentBuilder.timestamp(time))
                .font(Theme.mono(11)).monospacedDigit()
                .foregroundStyle(Theme.text3)
                .frame(width: 46, alignment: .leading).padding(.top, 5)
            Text(text)
                .font(Theme.serif).lineSpacing(6)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The live tail: dimmed hypothesis + a blinking caret (the redesign's signature).
private struct LiveTailRow: View {
    let hypothesis: String
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Color.clear.frame(width: 46, height: 1)
            TimelineView(.periodic(from: .now, by: 0.55)) { ctx in
                let on = reduce ? true : Int(ctx.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
                Text(tail(caretVisible: on))
                    .font(Theme.serif).lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func tail(caretVisible: Bool) -> AttributedString {
        var s = AttributedString(hypothesis)
        s.foregroundColor = Theme.text3
        var caret = AttributedString("▏")
        caret.foregroundColor = caretVisible ? Theme.accent : .clear   // toggle color → no layout jump
        return s + caret
    }
}

// MARK: - Summary canvas

struct SummaryCanvas: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.isSummarizing && model.summary.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Summarizing on-device…").font(Theme.ui(14)).foregroundStyle(Theme.text2)
                    }.padding(.vertical, 8)
                } else {
                    let parsed = SummaryParse.parse(model.summary)
                    if let error = parsed.error {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text(error.replacingOccurrences(of: "⚠︎ ", with: ""))
                                .font(Theme.ui(14)).foregroundStyle(Theme.text2)
                        }
                    } else {
                        if !parsed.lead.isEmpty {
                            Text(parsed.lead).font(Theme.ui(15.5)).lineSpacing(5).foregroundStyle(Theme.text)
                                .frame(maxWidth: 560, alignment: .leading).padding(.bottom, 20)
                        }
                        if !parsed.points.isEmpty {
                            Text("KEY POINTS").font(Theme.ui(11, weight: .medium)).tracking(1.5)
                                .foregroundStyle(Theme.text3).padding(.bottom, 12)
                            VStack(alignment: .leading, spacing: 13) {
                                ForEach(Array(parsed.points.enumerated()), id: \.offset) { _, point in
                                    HStack(alignment: .top, spacing: 11) {
                                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.accent).padding(.top, 3)
                                        Text(point).font(Theme.ui(14)).lineSpacing(3).foregroundStyle(Theme.text2)
                                    }
                                }
                            }.frame(maxWidth: 560, alignment: .leading)
                        }
                    }
                    if !model.isSummarizing && !model.summary.isEmpty {
                        footer
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 34).padding(.top, 28).padding(.bottom, 30)
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.summaryEdge).frame(height: 2) }
    }

    private var footer: some View {
        VStack(spacing: 16) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 10) {
                GhostButton(system: "doc.on.doc", title: "Copy") { copy() }
                GhostButton(system: "arrow.clockwise", title: "Regenerate") { model.summarizeTranscript() }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.aiTint).font(.system(size: 12))
                    Text("On-device · Apple Intelligence")
                }.font(Theme.ui(11.5)).foregroundStyle(Theme.text3)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.top, 24)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.summary, forType: .string)
    }
}

struct GhostButton: View {
    let system: String
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: system).font(.system(size: 12))
                Text(title).font(Theme.ui(12.5, weight: .medium))
            }
            .foregroundStyle(hover ? Theme.text : Theme.text2)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.06) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline2))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

enum SummaryParse {
    /// Split the model's summary into a lead paragraph + bullet points (it's prompted to produce
    /// a 1–2 sentence overview then 3–6 bullets). Lines starting with a bullet glyph become points.
    static func parse(_ s: String) -> (lead: String, points: [String], error: String?) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ("", [], nil) }
        if trimmed.hasPrefix("⚠︎") { return ("", [], trimmed) }
        var lead: [String] = []
        var points: [String] = []
        for raw in trimmed.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let f = line.first, "•-*–‣◦".contains(f) {
                points.append(String(line.drop(while: { "•-*–‣◦ \t".contains($0) })))
            } else if points.isEmpty {
                lead.append(line)
            } else {
                points[points.count - 1] += " " + line
            }
        }
        return (lead.joined(separator: " "), points, nil)
    }
}
