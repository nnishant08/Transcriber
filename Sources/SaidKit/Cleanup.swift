import Foundation

/// Feature D1 — non-destructive transcript cleanup via on-device FoundationModels.
///
/// The cleaned form lives ONLY as `cleanedText` per segment inside `session.json`; the verbatim
/// `transcript.md` (the canonical record) is NEVER touched. Cleanup operates per segment in small
/// batches whose boundaries are preserved, so every `[mm:ss]` timestamp and segment count survive
/// exactly — timing can't drift. When Apple Intelligence is unavailable or a call fails, the
/// affected segments simply keep no cleaned form (verbatim-only), never an error.
public enum TranscriptCleanup {

    public static var isAvailable: Bool { Summarizer.isAvailable }

    /// Fill `cleanedText` on each segment (leaving `start`/`end`/`text` and the array count
    /// untouched). Segments that already have a cleaned form keep it. Returns the input unchanged
    /// when the model is unavailable.
    public static func cleanSegments(_ segments: [TranscriptSegment]) async -> [TranscriptSegment] {
        guard isAvailable, !segments.isEmpty else { return segments }
        var out = segments
        let batchSize = 8
        var start = 0
        while start < out.count {
            let range = start ..< min(start + batchSize, out.count)
            let indices = range.filter { out[$0].cleanedText == nil && !out[$0].text.trimmingCharacters(in: .whitespaces).isEmpty }
            if !indices.isEmpty {
                do {
                    let cleaned = try await cleanBatch(indices.map { out[$0].text })
                    for (j, idx) in indices.enumerated() where j < cleaned.count {
                        if let c = cleaned[j], !c.isEmpty { out[idx].cleanedText = c }
                    }
                } catch {
                    NSLog("[Cleanup] batch failed (\(error)) — those segments stay verbatim-only")
                }
            }
            start = range.upperBound
        }
        return out
    }

    /// One model call cleaning a batch of numbered lines. The instructions are deliberately
    /// constrained to *within-line* cleanup: no additions, no paraphrase, no translation, no
    /// merging/splitting — so segment boundaries (and their timestamps) cannot move.
    static func cleanBatch(_ texts: [String]) async throws -> [String?] {
        let instructions = """
            You clean up raw speech-transcript lines. Each input line starts with its number and \
            "| ". For EACH input line, output one line that starts with the SAME number and "| ", \
            followed by the cleaned text: remove filler words (um, uh, ah, er, and "you know"/"like" \
            when used as pure filler), remove false starts and stutters, and fix punctuation and \
            capitalization. Do NOT add words, do NOT summarize or paraphrase, do NOT translate, do \
            NOT merge or split lines, do NOT reorder. If a line needs no change, repeat it as-is. \
            Example: the input line "3| um, we, we shipped it" becomes "3| We shipped it." \
            Output exactly one line per input line, nothing else.
            """
        var prompt = ""
        for (i, t) in texts.enumerated() { prompt += "\(i + 1)| \(t)\n" }
        let raw = try await Intelligence.run(instructions: instructions, prompt: prompt,
                                             temperature: 0.1, maxTokens: 1500)
        return parseBatch(raw, count: texts.count)
    }

    /// Parse "N| text" lines back into a count-sized array (nil where the model skipped or
    /// mangled a line — those segments just stay verbatim-only).
    public static func parseBatch(_ raw: String, count: Int) -> [String?] {
        var out = [String?](repeating: nil, count: count)
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sep = t.firstIndex(of: "|") else { continue }
            let numPart = t[..<sep].trimmingCharacters(in: CharacterSet(charactersIn: " .)-"))
            guard let n = Int(numPart), (1...count).contains(n) else { continue }
            var text = String(t[t.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            // Defensive: strip a stray echoed "N|" / "<digits>|" prefix (a model occasionally
            // copies the format token literally).
            if let stray = text.range(of: #"^(N|\d+)\|\s*"#, options: .regularExpression) {
                text.removeSubrange(stray)
            }
            if !text.isEmpty { out[n - 1] = text }
        }
        return out
    }
}

/// The post-save cleanup pass. Runs OFF the save path (after diarization in the same serial
/// chain, so the two passes' read-modify-writes of session.json can't race). Writes ONLY
/// `session.json` — `transcript.md` stays the untouched verbatim record.
public enum CleanupPass {

    public static func run(dir: URL) async {
        guard TranscriptCleanup.isAvailable else { return }
        guard let doc = DocumentBuilder.readSession(dir), !doc.segments.isEmpty,
              doc.segments.contains(where: { $0.cleanedText == nil }) else { return }
        let cleaned = await TranscriptCleanup.cleanSegments(doc.segments)
        guard cleaned.contains(where: { $0.cleanedText != nil }) else { return }
        // Merge onto a FRESH read so we can't clobber fields another writer updated meanwhile.
        guard var fresh = DocumentBuilder.readSession(dir), fresh.segments.count == cleaned.count else { return }
        for i in fresh.segments.indices { fresh.segments[i].cleanedText = cleaned[i].cleanedText }
        DocumentBuilder.writeSessionJSON(fresh, to: dir)
        SessionStore.postSessionSaved(dir)
        NSLog("[Cleanup] cleaned \(cleaned.filter { $0.cleanedText != nil }.count)/\(cleaned.count) segments for \(dir.lastPathComponent)")
    }
}

/// A user-authored summary template (Feature D2). Persisted as JSON in UserDefaults; outputs are
/// cached in `SessionMeta.summaries` under `cacheKey` (namespaced so it can't collide with the
/// built-in `SummaryStyle` raw values).
public struct CustomSummaryMode: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var instructions: String
    public var id: String { name }
    public var cacheKey: String { "custom:\(name)" }

    public init(name: String, instructions: String) {
        self.name = name
        self.instructions = instructions
    }
}
