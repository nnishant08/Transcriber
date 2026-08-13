import Foundation

/// One matched excerpt within a session, with the nearest `[mm:ss]` timestamp (nil if unknown).
public struct SearchSnippet: Sendable {
    public let timestamp: String?
    public let text: String
}

/// A ranked search result: a session plus why it matched. Self-contained so a later "chat with your
/// sessions" feature can reuse `SearchIndex.search(_:)` directly.
public struct SessionHit: Sendable, Identifiable {
    public let dir: URL
    public let meta: SessionMeta
    let score: Double
    public let matchCount: Int
    public let snippets: [SearchSnippet]

    public var id: String { dir.path }
    public var title: String {
        if let raw = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let cleaned = TitleGenerator.sanitizeTitle(raw)
            if !cleaned.isEmpty { return cleaned }
        }
        return TitleGenerator.fallbackTitle(transcript: snippets.first?.text ?? "", date: meta.date)
    }
}

/// In-app, on-device keyword full-text index over every session's `transcript.md` (which, for visual
/// sessions, already contains the OCR'd slide text). No Spotlight, no new dependencies.
///
/// Correctness always comes from disk: a small JSON cache under Application Support gives a fast cold
/// start, but `rebuildFromDisk()` re-reads any transcript whose mtime changed and drops vanished
/// sessions, and `index(sessionDir:)` updates one session incrementally on save. Thread-safe (an
/// internal lock) so it can be built off-main and queried from the UI.
public final class SearchIndex: @unchecked Sendable {
    public static let shared = SearchIndex(cacheURL: SearchIndex.defaultCacheURL)

    private struct Entry: Codable {
        var path: String
        public var date: Date
        public var title: String?
        public var tags: [String]
        var mtime: Date
        var termFreq: [String: Int]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]      // keyed by session dir path
    private let cacheURL: URL

    /// `cacheURL` is injectable so self-tests get an isolated cache (and don't touch the app's).
    public init(cacheURL: URL) {
        self.cacheURL = cacheURL
        loadCache()
    }

    // MARK: - Building

    /// Reconcile the in-memory index with disk: reuse cached entries whose `transcript.md` mtime is
    /// unchanged, re-index changed/new sessions, drop sessions that no longer exist. Persists the cache.
    public func rebuildFromDisk(root: URL = SessionStore.root) {
        let dirs = SessionStore.sessionDirectoryURLs(root: root)
        let present = Set(dirs.map { $0.path })
        lock.lock()
        entries = entries.filter { present.contains($0.key) }
        lock.unlock()

        for dir in dirs {
            let mtime = transcriptMTime(dir)
            lock.lock(); let cached = entries[dir.path]; lock.unlock()
            if let cached, abs(cached.mtime.timeIntervalSince(mtime)) < 0.5 { continue }   // still fresh
            indexInternal(dir: dir, mtime: mtime)
        }
        saveCache()
    }

    /// (Re)index a single session and persist. Called on each session save and after title backfill.
    public func index(sessionDir dir: URL) {
        indexInternal(dir: dir, mtime: transcriptMTime(dir))
        saveCache()
    }

    /// Remove a session from the index (e.g. after delete-to-Trash) and persist.
    public func remove(dir: URL) {
        lock.lock(); entries[dir.path] = nil; lock.unlock()
        saveCache()
    }

    private func indexInternal(dir: URL, mtime: Date) {
        let text = SessionStore.transcriptPlainText(dir: dir)
        let meta = DocumentBuilder.readSession(dir)?.meta ?? SessionStore.synthMeta(dir: dir)
        var freq: [String: Int] = [:]
        for term in Self.tokenize(text) { freq[term, default: 0] += 1 }
        let entry = Entry(path: dir.path, date: meta.date, title: meta.title,
                          tags: meta.tags, mtime: mtime, termFreq: freq)
        lock.lock(); entries[dir.path] = entry; lock.unlock()
    }

    // MARK: - Query

    /// Ranked sessions matching the query. Ranking = total match count + an all-terms bonus + a
    /// recency boost. Each hit carries matched snippets with the nearest `[mm:ss]` timestamp.
    public func search(_ query: String) -> [SessionHit] {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty else { return [] }
        lock.lock(); let snapshot = entries; lock.unlock()
        let now = Date()

        var hits: [SessionHit] = []
        for (_, e) in snapshot {
            var matchCount = 0, matchedTerms = 0
            for t in terms {
                if let f = e.termFreq[t] { matchCount += f; matchedTerms += 1 }
            }
            guard matchCount > 0 else { continue }
            let ageDays = max(0, now.timeIntervalSince(e.date)) / 86_400
            let recency = 1.0 / (1.0 + ageDays / 30.0)                          // ~1 now, decays over weeks
            let allBonus = (matchedTerms == terms.count) ? Double(terms.count) : 0
            let score = Double(matchCount) + allBonus + recency

            let dir = URL(fileURLWithPath: e.path)
            let meta = DocumentBuilder.readSession(dir)?.meta
                ?? SessionMeta(date: e.date, sourceLabel: "Unknown", modelName: "", title: e.title, tags: e.tags)
            let snippets = Self.extractSnippets(dir: dir, terms: terms, limit: 3)
            hits.append(SessionHit(dir: dir, meta: meta, score: score, matchCount: matchCount, snippets: snippets))
        }
        hits.sort { $0.score == $1.score ? $0.meta.date > $1.meta.date : $0.score > $1.score }
        return hits
    }

    // MARK: - Tokenizing / snippets

    /// Lowercase alphanumeric tokens of length ≥ 2.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber { cur.append(ch) }
            else { if cur.count >= 2 { out.append(cur) }; cur = "" }
        }
        if cur.count >= 2 { out.append(cur) }
        return out
    }

    /// Scan `transcript.md` for lines containing any query term, returning up to `limit` snippets,
    /// each tagged with the nearest preceding `[mm:ss]` timestamp.
    static func extractSnippets(dir: URL, terms: [String], limit: Int) -> [SearchSnippet] {
        guard let raw = SessionIO.readText(dir.appendingPathComponent("transcript.md")) else { return [] }
        // Drop the metadata header up to and including the first `---`, so the `**Date:** …:…:…`
        // line can't leak its wall-clock time as a fake snippet timestamp (legacy transcripts have
        // no in-body [mm:ss] → snippet timestamp is correctly nil).
        var lines = raw.components(separatedBy: "\n")
        if let sep = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeFirst(sep + 1)
        }
        let termSet = Set(terms)
        var snippets: [SearchSnippet] = []
        var currentTS: String? = nil
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if let ts = SessionStore.firstTimestamp(in: t) { currentTS = ts }
            // Skip structural lines (header, image, details/summary, code fences).
            if t.hasPrefix("#") || t == "---" || t.hasPrefix("- **") || t.hasPrefix("![")
                || t.hasPrefix("<details") || t.hasPrefix("</details") || t.hasPrefix("<summary")
                || t.hasPrefix("```") { continue }
            if Set(tokenize(t)).isDisjoint(with: termSet) { continue }
            let clean = SessionStore.stripLeadingTimestamp(stripMarkup(t))
            if clean.isEmpty { continue }
            snippets.append(SearchSnippet(timestamp: currentTS, text: String(clean.prefix(180))))
            if snippets.count >= limit { break }
        }
        return snippets
    }

    private static func stripMarkup(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    // MARK: - Persistence

    private func transcriptMTime(_ dir: URL) -> Date {
        (try? dir.appendingPathComponent("transcript.md").resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
    }

    private func loadCache() {
        // Encryption ON (Feature C4) ⇒ the index is in-memory only: a plaintext cache on disk would
        // defeat encryption-at-rest, so we never read or write one. Correctness still comes from disk
        // (rebuildFromDisk reads each transcript via the decrypting SessionIO seam at launch).
        guard !SessionIO.isEncryptionEnabled else { return }
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        lock.lock(); entries = decoded; lock.unlock()
    }

    private func saveCache() {
        guard !SessionIO.isEncryptionEnabled else { return }   // in-memory only when encrypted
        lock.lock(); let snapshot = entries; lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    static var defaultCacheURL: URL {
        // Folder name kept across the rebrand on purpose: it is a stored PATH, not a user-visible
        // string. Renaming it would orphan every existing index cache (harmless — the index always
        // rebuilds from disk — but a pointless cold start for no visible gain).
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("search-index.json")
    }
}
