import SwiftUI
import AppKit

/// Cross-session "Ask" (A2): retrieve over the whole corpus via SearchIndex, answer on-device with
/// links back to the source sessions (which open in the Viewer). Reachable from the Library + menu bar.
@MainActor
final class AskModel: ObservableObject {
    @Published var query = ""
    @Published var answer = ""
    @Published var sources: [SessionHit] = []
    @Published var isAsking = false
    @Published var asked = false

    func ask() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !isAsking else { return }
        isAsking = true; asked = true; answer = ""; sources = []
        Task {
            defer { isAsking = false }
            let result = await Intelligence.ask(question: q, index: SearchIndex.shared)
            answer = result.text
            sources = result.sources
        }
    }
}

struct AskWindow: View {
    @StateObject private var m = AskModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles.rectangle.stack").foregroundStyle(Theme.aiTint)
                Text("Ask your sessions").font(Theme.ui(14, weight: .semibold))
                Spacer()
                OnDeviceBadge()
            }
            .padding(14).background(Theme.titlebar)
            Divider().overlay(Theme.hairline)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.text2)
                TextField("Ask a question across all your sessions…", text: $m.query)
                    .textFieldStyle(.plain).font(Theme.ui(14)).onSubmit { m.ask() }
                Button { m.ask() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .disabled(m.query.trimmingCharacters(in: .whitespaces).isEmpty || m.isAsking)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
            .padding(14)

            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if m.isAsking {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching + answering on-device…").font(Theme.ui(13)).foregroundStyle(Theme.text2) }
                    } else if !m.answer.isEmpty {
                        CitationAnswer(text: m.answer)
                    } else if m.asked {
                        Text("No answer.").font(Theme.ui(13)).foregroundStyle(Theme.text3)
                    } else if !Intelligence.isAvailable {
                        Text(Intelligence.availabilityMessage() ?? "Apple Intelligence is unavailable — Ask will still list matching sessions.")
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.text3)
                    } else {
                        Text("Ask anything — answers are grounded in your transcripts and link back to the source sessions.")
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.text3)
                    }

                    if !m.sources.isEmpty {
                        Text("SOURCES").font(Theme.ui(10.5, weight: .medium)).tracking(1.2).foregroundStyle(Theme.text3)
                        ForEach(m.sources) { hit in
                            Button { WindowManager.shared.showViewer(dir: hit.dir) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hit.title).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.accentText).lineLimit(1)
                                    if let s = hit.snippets.first {
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text(s.timestamp ?? "—").font(Theme.mono(10.5)).foregroundStyle(Theme.text3)
                                            Text(s.text).font(Theme.ui(12)).foregroundStyle(Theme.text2).lineLimit(2)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.windowBG)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
    }
}

/// The Ask answer with clickable `[mm:ss]` (no audio to seek here, so they're inert text but still
/// rendered; clicking a SOURCE opens that session's Viewer).
private struct CitationAnswer: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.ui(14)).lineSpacing(4).foregroundStyle(Theme.text)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}
