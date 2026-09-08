import SwiftUI
import UIKit
import SaidKit

/// Screen 10 — Hand it over.
///
/// A session is a thing you can hand over: a `.said` bundle is the whole folder — words, audio,
/// slides, everything — and the Mac claims the type and imports it whole, keeping the identity.
///
/// **The size is shown BEFORE the share sheet opens**, not after. A slide lecture is a few
/// megabytes; a Mac screen recording is not, and that difference decides whether the user AirDrops
/// it or gives up halfway through.
struct SendSheet: View {
    let dir: URL
    let meta: SessionMeta

    @Environment(\.dismiss) private var dismiss
    @State private var preparing = false
    @State private var share: SharePayload?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fileCard

                    SectionRule(title: "Send")
                    PressedButton(kind: .violet) { Task { await sendBundle() } } label: {
                        HStack(spacing: 9) {
                            if preparing { ProgressView().tint(.white) }
                            Text(preparing ? "Packing…" : "Send the whole session")
                                .font(Theme.ui(16, weight: .semibold))
                        }
                    }
                    Text("A .said file: the transcript, the audio, and any slides. Opens complete on a Mac.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.text3)

                    SectionRule(title: "Or save as")
                    exportRow("Transcript", "Markdown") { try exportMarkdown() }
                    exportRow("Subtitles", "SRT") { try exportSRT() }
                    exportRow("Document", "PDF") { try await exportPDF() }

                    if let error {
                        Text(error).font(Theme.ui(12)).foregroundStyle(Palette.amberInk2)
                    }
                    Color.clear.frame(height: 30)
                }
                .padding(20)
            }
            .background(Theme.windowBG)
            .navigationTitle("Hand it over")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .sheet(item: $share) { payload in ActivityView(items: [payload.url]) }
    }

    private var fileCard: some View {
        StickerCard {
            HStack(spacing: 12) {
                BlobPair(size: 11)
                    .frame(width: 44, height: 52)
                    .background(Palette.violet)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(meta.title?.isEmpty == false ? meta.title! : dir.lastPathComponent)
                        .font(Theme.ui(15, weight: .semibold)).lineLimit(1)
                    Text(sizeLine).font(Theme.mono(11)).foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 0)
            }
            .padding(15)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session: \(meta.title ?? ""). \(sizeLine)")
    }

    /// Duration · what's in it · how big. All three matter before an AirDrop.
    private var sizeLine: String {
        var parts: [String] = []
        if let d = meta.durationSeconds, d > 0 { parts.append(DocumentBuilder.timestamp(d)) }
        var kinds: [String] = []
        if meta.audioFile != nil { kinds.append("audio") }
        if meta.hasVideo { kinds.append("video") }
        if !kinds.isEmpty { parts.append(kinds.joined(separator: " + ")) }
        parts.append(Self.formattedSize(of: dir))
        return parts.joined(separator: " · ")
    }

    static func formattedSize(of dir: URL) -> String {
        let fm = FileManager.default
        var total: Int64 = 0
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func exportRow(_ title: String, _ format: String,
                           _ work: @escaping () async throws -> URL) -> some View {
        Button {
            Task {
                do { share = SharePayload(url: try await work()) }
                catch { self.error = error.localizedDescription }
            }
        } label: {
            HStack {
                Text(title).font(Theme.ui(15)).foregroundStyle(Theme.text)
                Spacer()
                Text(format).font(Theme.ui(14)).foregroundStyle(Theme.text3)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(Theme.surface)
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Export paths — all through SaidKit, none reimplemented here.

    private func sendBundle() async {
        preparing = true
        defer { preparing = false }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).\(SessionBundle.fileExtension)")
        do { share = SharePayload(url: try SessionBundle.write(sessionDir: dir, to: out)) }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    private func exportMarkdown() throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).md")
        let md = SessionIO.readText(SessionPaths.transcriptURL(in: dir)) ?? ""
        try Data(md.utf8).write(to: out)
        return out
    }

    private func exportSRT() throws -> URL {
        guard let srt = Subtitles.srt(dir: dir) else {
            throw NSError(domain: "Said", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This session has no per-line timings to build subtitles from."])
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).srt")
        try Data(srt.utf8).write(to: out)
        return out
    }

    private func exportPDF() async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).pdf")
        return try await Exporter.exportPDF(sessionDir: dir, to: out)
    }

    private var safeName: String {
        let raw = meta.title?.isEmpty == false ? meta.title! : dir.lastPathComponent
        return raw.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SharePayload: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// `UIActivityViewController` — AirDrop and everything else. Wrapped because there is no SwiftUI
/// equivalent, which is exactly the case §4 allows one for.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
