import SaidKit
import Foundation
import AppKit

/// Send-to helpers that need NO Automation/Apple-Events permission:
/// - the macOS **share sheet** (`NSSharingServicePicker`) routes to Notes, Mail, Messages, etc.;
/// - **Obsidian** via writing a `.md` into a user-chosen vault folder, or the `obsidian://new` URL scheme.
enum Sharing {

    /// Present the system share sheet for the given items (file URLs and/or strings), anchored to the
    /// key window. The user picks the destination (Notes, Mail, AirDrop, …) — no extra permission.
    @MainActor
    static func presentShareSheet(items: [Any], anchor: NSView? = nil) {
        guard !items.isEmpty else { return }
        let picker = NSSharingServicePicker(items: items)
        let view = anchor ?? NSApp.keyWindow?.contentView
        guard let view else { return }
        let rect = NSRect(x: view.bounds.midX - 1, y: view.bounds.maxY - 40, width: 2, height: 2)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    // MARK: - Obsidian

    /// A clean markdown rendering for Obsidian (front-matter tags + timestamped transcript).
    static func obsidianMarkdown(dir: URL) -> String {
        let meta = DocumentBuilder.readSession(dir)?.meta
        var out = ""
        if let meta {
            out += "---\n"
            out += "title: \(meta.title ?? "Transcript")\n"
            out += "date: \(ISO8601DateFormatter().string(from: meta.date))\n"
            if !meta.tags.isEmpty { out += "tags: [\(meta.tags.joined(separator: ", "))]\n" }
            out += "source: \(meta.sourceLabel)\n"
            out += "---\n\n"
            out += "# \(meta.title ?? "Transcript")\n\n"
        }
        out += SessionStore.timestampedTranscript(dir: dir, maxChars: 5_000_000)
        return out
    }

    /// Write the session's markdown into an Obsidian vault folder as `<title>.md`. Returns the file URL.
    @discardableResult
    static func writeToObsidian(dir: URL, vaultFolder: URL) throws -> URL {
        let meta = DocumentBuilder.readSession(dir)?.meta
        let base = exportFilename(meta?.title?.isEmpty == false ? meta!.title! : dir.lastPathComponent)
        var dest = vaultFolder.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = vaultFolder.appendingPathComponent("\(base) \(n).md"); n += 1
        }
        try Data(obsidianMarkdown(dir: dir).utf8).write(to: dest)
        return dest
    }

    /// `obsidian://new?vault=…&name=…&content=…` — opens Obsidian and creates a note (content is
    /// URL-encoded; long transcripts are better written to the vault folder via `writeToObsidian`).
    static func obsidianNewNoteURL(vault: String?, title: String, content: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "new"
        var items = [URLQueryItem(name: "name", value: title),
                     URLQueryItem(name: "content", value: content)]
        if let vault, !vault.isEmpty { items.insert(URLQueryItem(name: "vault", value: vault), at: 0) }
        comps.queryItems = items
        return comps.url
    }

    /// Public filename sanitizer for save panels / exports (strips path-illegal characters).
    /// Same rules the transcript file itself is named by — one sanitizer, in SaidKit.
    static func exportFilename(_ s: String) -> String { SessionPaths.exportFilename(s) }
}
