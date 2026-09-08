import SwiftUI
import SaidKit

/// The gist — summaries through SaidKit's existing `Intelligence`, cached in `meta.summaries`
/// exactly as on the Mac, so the same session and style produce the same text on both.
struct GistTab: View {
    @ObservedObject var model: SessionModel
    @State private var text = ""
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !Intelligence.isAvailable {
                    UnavailableNotice(what: "Summaries")
                } else if text.isEmpty && !working {
                    PressedButton(kind: .violet) { Task { await summarize() } } label: {
                        Text("Sum it up").font(Theme.ui(16, weight: .semibold))
                    }
                } else if working {
                    HStack(spacing: 10) {
                        ProgressView().tint(Palette.violet)
                        Text("Reading it back…").font(Theme.ui(14)).foregroundStyle(Theme.text2)
                    }
                } else {
                    gistCard
                }
                Color.clear.frame(height: 150)
            }
            .padding(.horizontal, 20)
        }
        .onAppear { text = model.meta.summaries[SummaryStyle.tldr.rawValue] ?? "" }
    }

    /// Amber, because it is the thing you came back for.
    private var gistCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Blob(size: 11, color: Palette.amberInk2)
                Text("IN A SENTENCE")
                    .font(Theme.mono(10, weight: .medium)).tracking(1.1)
                    .foregroundStyle(Palette.amberInk2)
            }
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Palette.amberInk)
                .textSelection(.enabled)
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.amberTint)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func summarize() async {
        working = true
        defer { working = false }
        let source = SessionStore.timestampedTranscript(dir: model.dir)
        guard !source.isEmpty else { return }
        if let out = try? await Intelligence.summarize(transcript: source, style: .tldr) {
            text = out
            cache(out)
        }
    }

    /// Cache under the SAME key the Mac uses, so a session summarised on either device reopens
    /// instantly on the other.
    private func cache(_ value: String) {
        guard var doc = DocumentBuilder.readSession(model.dir) else { return }
        doc.meta.summaries[SummaryStyle.tldr.rawValue] = value
        DocumentBuilder.writeSessionJSON(doc, to: model.dir)
    }
}

/// To do — the action items, as violet task stickers.
struct TasksTab: View {
    @ObservedObject var model: SessionModel
    @State private var items: [String] = []
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !Intelligence.isAvailable {
                    UnavailableNotice(what: "Action items")
                } else if items.isEmpty && !working {
                    PressedButton(kind: .violet) { Task { await extract() } } label: {
                        Text("Find the commitments").font(Theme.ui(16, weight: .semibold))
                    }
                } else if working {
                    ProgressView().tint(Palette.violet)
                } else {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(.white, lineWidth: 2.5)
                                .frame(width: 17, height: 17)
                            Text(item).font(Theme.ui(13, weight: .medium)).foregroundStyle(.white)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 13).padding(.vertical, 11)
                        .background(Palette.violet)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                Color.clear.frame(height: 150)
            }
            .padding(.horizontal, 20)
        }
        .onAppear { items = model.meta.actionItems }
    }

    private func extract() async {
        working = true
        defer { working = false }
        let source = SessionStore.timestampedTranscript(dir: model.dir)
        guard !source.isEmpty else { return }
        let found = await Intelligence.actionItems(transcript: source)   // non-throwing
        guard !found.isEmpty else { return }
        items = found
        guard var doc = DocumentBuilder.readSession(model.dir) else { return }
        doc.meta.actionItems = found
        DocumentBuilder.writeSessionJSON(doc, to: model.dir)
    }
}

/// The honest hardware limit — not a broken feature, and not an upsell.
///
/// Apple Intelligence needs an iPhone 15 Pro or newer, which most devices are not. Everything else
/// in the app works fully, and this says so plainly.
struct UnavailableNotice: View {
    let what: String

    var body: some View {
        StickerCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Blob(size: 10, color: Palette.violet)
                    Text("\(what) need Apple Intelligence")
                        .font(Theme.ui(15, weight: .semibold))
                }
                Text(Intelligence.availabilityMessage()
                     ?? "This iPhone doesn't support Apple Intelligence, so Said can't write summaries on it. Recording, transcription, search and export all work as normal.")
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
