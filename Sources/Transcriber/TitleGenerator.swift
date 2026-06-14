import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device auto-titling + tagging for a session transcript, via Apple's Foundation Models
/// (same availability/`#available(macOS 26)` pattern as `Summarizer`). Everything stays local.
/// When Apple Intelligence is unavailable, both paths degrade to a deterministic fallback title
/// derived from the transcript's first words (or the date) and empty tags — generation NEVER fails.
enum TitleGenerator {
    struct Result: Sendable { let title: String; let tags: [String] }

    /// Deterministic, model-free title: the first meaningful words of the transcript, else the date.
    static func fallbackTitle(transcript: String, date: Date) -> String {
        let words = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        if words.isEmpty { return "Session " + stamp.string(from: date) }
        return sanitizeTitle(words.prefix(8).joined(separator: " "))
    }

    /// Generate a concise title + up to 5 tags from a transcript. Falls back gracefully when the
    /// on-device model is unavailable or errors. Safe to call off the main thread.
    static func generate(transcript: String, date: Date) async -> Result {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = Result(title: fallbackTitle(transcript: text, date: date), tags: [])
        guard !text.isEmpty else { return fallback }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return fallback }
            do {
                let clipped = String(text.prefix(6000))     // stay within the on-device context window
                let session = LanguageModelSession(instructions: """
                    You label spoken-word transcripts. Respond with EXACTLY two lines and nothing else:
                    TITLE: a concise title of at most 8 words (no quotes, no trailing period)
                    TAGS: up to 5 short lowercase topic keywords, comma-separated
                    Base everything only on the transcript; do not invent specifics.
                    """)
                let response = try await session.respond(to: "Transcript:\n\n\(clipped)")
                let parsed = parse(response.content)
                let title = parsed.title.isEmpty ? fallback.title : parsed.title
                return Result(title: title, tags: parsed.tags)
            } catch {
                return fallback
            }
        }
        #endif
        return fallback
    }

    /// Generate ONLY tags (≤5) from a transcript via a focused prompt — more reliable than asking for
    /// a title + tags together (the combined prompt sometimes omits the tags line on long inputs).
    /// Returns [] when unavailable/empty/errored. Used by the tag-backfill maintenance path.
    static func generateTags(transcript: String) async -> [String] {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return [] }
            do {
                let clipped = String(text.prefix(6000))
                let session = LanguageModelSession(instructions: """
                    You extract topic keywords from a spoken-word transcript. Respond with ONLY one line:
                    a comma-separated list of 3 to 5 short lowercase topic keywords — no labels, no other text.
                    Base them only on the transcript.
                    """)
                let response = try await session.respond(to: "Transcript:\n\n\(clipped)")
                return sanitizeTags(response.content)
            } catch {
                return []
            }
        }
        #endif
        return []
    }

    // MARK: - Parsing / sanitizing (defensive — the model may ignore the format)

    static func parse(_ raw: String) -> Result {
        var title = ""
        var tags: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let t = stripMarkdownMarkers(line.trimmingCharacters(in: .whitespaces))
            if t.lowercased().hasPrefix("title:") {
                title = sanitizeTitle(String(t.dropFirst("title:".count)))
            } else if t.lowercased().hasPrefix("tags:") {
                tags = sanitizeTags(String(t.dropFirst("tags:".count)))
            }
        }
        // If the model ignored the format entirely, fall back to the first non-empty line as a title.
        if title.isEmpty,
           let first = raw.components(separatedBy: .newlines)
               .map({ $0.trimmingCharacters(in: .whitespaces) })
               .first(where: { !$0.isEmpty }) {
            title = sanitizeTitle(first)
        }
        return Result(title: title, tags: tags)
    }

    static func sanitizeTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for q in ["\"", "“", "”", "‘", "’", "`", "*"] { t = t.replacingOccurrences(of: q, with: "") }  // incl. markdown bold
        t = stripMarkdownMarkers(t)
        // Strip a leaked "TITLE:" label even when the model wrapped it (e.g. "**Title:**" → "*" removed above).
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst("title:".count)).trimmingCharacters(in: .whitespaces) }
        t = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")   // collapse whitespace
        let words = t.split(separator: " ")
        if words.count > 8 { t = words.prefix(8).joined(separator: " ") }
        if t.count > 80 { t = String(t.prefix(80)).trimmingCharacters(in: .whitespaces) }
        while let last = t.last, ".,;:".contains(last) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Strip leading markdown list/heading markers (`#`, `-`, `>`, `•`, `*`) and surrounding whitespace.
    static func stripMarkdownMarkers(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while let f = t.first, "#->•*".contains(f) { t.removeFirst(); t = t.trimmingCharacters(in: .whitespaces) }
        return t
    }

    static func sanitizeTags(_ s: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for part in s.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            var tag = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            tag = tag.replacingOccurrences(of: "\"", with: "")
            tag = tag.trimmingCharacters(in: CharacterSet(charactersIn: "#•*-.()[]"))
            tag = tag.trimmingCharacters(in: .whitespaces)
            if tag.count > 30 {                       // cap length, but never cut mid-word
                tag = String(tag.prefix(30))
                if let sp = tag.lastIndex(of: " ") { tag = String(tag[..<sp]) }
                tag = tag.trimmingCharacters(in: .whitespaces)
            }
            guard !tag.isEmpty, !seen.contains(tag) else { continue }
            seen.insert(tag)
            out.append(tag)
            if out.count >= 5 { break }
        }
        return out
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
}
