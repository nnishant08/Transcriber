import Foundation

/// One matched excerpt within a session, with the nearest `[mm:ss]` timestamp (nil if unknown).
public struct SearchSnippet: Sendable {
    public let timestamp: String?
    public let text: String
    /// True when this excerpt came from a SLIDE's OCR text rather than from speech (Phase 3,
    /// Wave 5). The Library renders those differently, because "this was written on a slide" and
    /// "someone said this" are different kinds of answer to the same query.
    public let isSlide: Bool

    public init(timestamp: String?, text: String, isSlide: Bool = false) {
        self.timestamp = timestamp
        self.text = text
        self.isSlide = isSlide
    }
}

/// A ranked search result: a session plus why it matched. Self-contained so a later "chat with your
/// sessions" feature can reuse `SearchIndex.search(_:)` directly.
public struct SessionHit: Sendable, Identifiable {
    public let dir: URL
    public let meta: SessionMeta
    let score: Double
    public let matchCount: Int
    public let snippets: [SearchSnippet]

    /// True when at least one matched excerpt came from a slide. Drives the Library's slide badge
    /// and the `slides:` search filter.
    /// `contains(where:)`, not `contains(_:)`: the unlabelled form is the Equatable-element
    /// overload, and `SearchSnippet` is deliberately not Equatable.
    public var hasSlideMatch: Bool { snippets.contains(where: \.isSlide) }

    /// Public because the `Said` module builds hits directly in two places: the semantic-only
    /// results in `Intelligence.retrieve`, and `--selftest-semantic`. The synthesized memberwise
    /// init is internal (`score` is), which would otherwise make both impossible from outside.
    public init(dir: URL, meta: SessionMeta, score: Double, matchCount: Int, snippets: [SearchSnippet]) {
        self.dir = dir
        self.meta = meta
        self.score = score
        self.matchCount = matchCount
        self.snippets = snippets
    }

    public var id: String { dir.path }
    public var title: String {
        if let raw = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let cleaned = TitleGenerator.sanitizeTitle(raw)
            if !cleaned.isEmpty { return cleaned }
        }
        return TitleGenerator.fallbackTitle(transcript: snippets.first?.text ?? "", date: meta.date)
    }
}

/// In-app, on-device keyword full-text index over every session's `transcript.md`.
///
/// A session with slide frames carries its OCR text in the SAME file (Phase 2 interleaves it into
/// the markdown), so slide text is searchable through this one index with no special handling —
/// there is deliberately no second index and no parallel OCR store. `--selftest-frames` asserts a
/// phrase that appeared only on a slide finds the session, and that the hit carries the frame's
/// `[mm:ss]`. No Spotlight, no new dependencies.
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
        /// Every term in the session, speech and slide text alike. UNCHANGED in meaning, so a
        /// session with no slides ranks exactly as it did before Phase 3.
        var termFreq: [String: Int]
        /// Slide OCR terms counted ONCE PER SLIDE SPAN. This is the de-duplicated slide signal.
        var slideTermFreq: [String: Int] = [:]
        /// Slide OCR terms counted once per captured FRAME — i.e. exactly the contribution slide
        /// text makes to `termFreq`, since `transcript.md` interleaves the OCR block per frame.
        ///
        /// Stored so the speech-only frequency can be recovered by EXACT subtraction rather than by
        /// re-tokenising a different string. That exactness is the point: a session with no frames
        /// has both slide tables empty, so speech == `termFreq` and its score is bit-for-bit what it
        /// was before Phase 3. No existing session's ranking moves.
        var slideFrameTermFreq: [String: Int] = [:]

        enum CodingKeys: String, CodingKey {
            case path, date, title, tags, mtime, termFreq, slideTermFreq, slideFrameTermFreq
        }

        init(path: String, date: Date, title: String?, tags: [String], mtime: Date,
             termFreq: [String: Int], slideTermFreq: [String: Int] = [:],
             slideFrameTermFreq: [String: Int] = [:]) {
            self.path = path; self.date = date; self.title = title; self.tags = tags
            self.mtime = mtime; self.termFreq = termFreq
            self.slideTermFreq = slideTermFreq; self.slideFrameTermFreq = slideFrameTermFreq
        }

        /// The slide tables are `decodeIfPresent` so a cache written before Phase 3 still loads;
        /// those sessions score as pure speech until their next re-index, which is correct.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            date = try c.decode(Date.self, forKey: .date)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            mtime = try c.decode(Date.self, forKey: .mtime)
            termFreq = try c.decode([String: Int].self, forKey: .termFreq)
            slideTermFreq = try c.decodeIfPresent([String: Int].self, forKey: .slideTermFreq) ?? [:]
            slideFrameTermFreq = try c.decodeIfPresent([String: Int].self, forKey: .slideFrameTermFreq) ?? [:]
        }
    }

    /// How much a slide-text match counts relative to a spoken one.
    ///
    /// Below 1 because slide text is much denser and much noisier than speech: a dense slide can
    /// carry more words than a minute of talking, and OCR contributes misreadings that were never on
    /// the slide at all. Weighting them equally lets one slide-heavy session outrank a session where
    /// someone actually discussed the thing being searched for.
    ///
    /// Not zero, and not close to it — a phrase that appeared ONLY on a slide and was never spoken
    /// still has to surface, since that is the differentiating capability this wave exists for.
    /// Tuned, not derived — see `PHASE3-REPORT.md`.
    static let slideMatchWeight = 0.35

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
        let doc = DocumentBuilder.readSession(dir)
        let meta = doc?.meta ?? SessionStore.synthMeta(dir: dir)
        var freq: [String: Int] = [:]
        for term in Self.tokenize(text) { freq[term, default: 0] += 1 }

        // Corrections are searchable, even though `transcript.md` never changes (Phase 3, §6).
        //
        // The edit overlay is deliberately not written into the verbatim file, so re-indexing after
        // an edit used to be a complete no-op: the corrected word reached the SEMANTIC index (which
        // chunks `EditStore.editedSegments`) and never reached this one, and the two disagreed about
        // the same session. What is missing is exactly the CORRECTED words — an edit's ORIGINAL is
        // still in the verbatim text and stays findable, which is right, since someone may well
        // search for what the machine wrote. So the delta is added rather than the text re-derived.
        for edit in EditStore.read(dir: dir) {
            for term in Self.tokenize(edit.corrected) { freq[term, default: 0] += 1 }
        }

        // Slide text, counted once per SPAN. `transcriptPlainText` above already contains the OCR
        // text once per captured FRAME — which is exactly the flooding problem: a slide left up for
        // ten minutes contributes its words dozens of times and drowns out the speech. Recording
        // the per-span counts separately lets `search` subtract the frames' over-counting back out
        // and weight what remains, without a second index or a change to the transcript format.
        var slideFreq: [String: Int] = [:]
        for span in doc?.slideSpans ?? [] {
            guard let t = span.text else { continue }
            for term in Self.tokenize(t) { slideFreq[term, default: 0] += 1 }
        }
        var slideFrameFreq: [String: Int] = [:]
        for frame in doc?.frames ?? [] {
            guard let t = frame.text else { continue }
            for term in Self.tokenize(t) { slideFrameFreq[term, default: 0] += 1 }
        }

        let entry = Entry(path: dir.path, date: meta.date, title: meta.title,
                          tags: meta.tags, mtime: mtime, termFreq: freq,
                          slideTermFreq: slideFreq, slideFrameTermFreq: slideFrameFreq)
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
            var weighted = 0.0
            for t in terms {
                if let f = e.termFreq[t] {
                    matchCount += f
                    matchedTerms += 1
                    // Split the match into speech and slide contributions and weight them
                    // differently. With no slide tables (every pre-Phase-3 session, and every
                    // session without frames) `fromFrames` is 0, so `weighted` collapses to
                    // `Double(matchCount)` and the score is exactly what it always was.
                    let fromFrames = e.slideFrameTermFreq[t] ?? 0
                    let speech = max(0, f - fromFrames)
                    let slideSpans = e.slideTermFreq[t] ?? 0
                    weighted += Double(speech) + Self.slideMatchWeight * Double(slideSpans)
                }
            }
            guard matchCount > 0 else { continue }
            let ageDays = max(0, now.timeIntervalSince(e.date)) / 86_400
            let recency = 1.0 / (1.0 + ageDays / 30.0)                          // ~1 now, decays over weeks
            let allBonus = (matchedTerms == terms.count) ? Double(terms.count) : 0
            let score = weighted + allBonus + recency

            let dir = URL(fileURLWithPath: e.path)
            let meta = DocumentBuilder.readSession(dir)?.meta
                ?? SessionMeta(date: e.date, sourceLabel: "Unknown", modelName: "", title: e.title, tags: e.tags)
            var snippets = Self.extractSnippets(dir: dir, terms: terms, limit: 3)
            // A term that exists only in a CORRECTION is in the index but not in `transcript.md`,
            // so the verbatim scan finds nothing and the hit would arrive with no excerpt at all.
            // Fall back to the edited view — and only then, so an unedited session does exactly what
            // it always did, down to the same allocations.
            if snippets.isEmpty { snippets = Self.editedSnippets(dir: dir, terms: terms, limit: 3) }
            hits.append(SessionHit(dir: dir, meta: meta, score: score, matchCount: matchCount, snippets: snippets))
        }
        hits.sort { $0.score == $1.score ? $0.meta.date > $1.meta.date : $0.score > $1.score }
        return hits
    }

    // MARK: - Tokenizing / snippets

    /// Lowercase alphanumeric tokens of length ≥ 2.
    ///
    /// **Public because it is the DEFINITION of "a searchable word" in Said**, not merely a helper.
    /// `SlideSegmenter` compares slide readings with it, and `--selftest-compare-engines` measures
    /// term recall with it — and a second implementation of this rule would be a place for the two
    /// to drift apart silently, which is strictly worse than one exposed function.
    public static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber { cur.append(ch) }
            else { if cur.count >= 2 { out.append(cur) }; cur = "" }
        }
        if cur.count >= 2 { out.append(cur) }
        return out
    }

    /// Snippets from the EDITED view, for terms that exist only in a correction.
    ///
    /// Separate from `extractSnippets` rather than folded into it: that function scans the raw
    /// markdown line by line and is on the path of every search, and the overlay costs a session
    /// read plus an apply. This runs only when the verbatim scan came back empty.
    static func editedSnippets(dir: URL, terms: [String], limit: Int) -> [SearchSnippet] {
        guard !EditStore.read(dir: dir).isEmpty,
              let doc = DocumentBuilder.readSession(dir) else { return [] }
        let segments = EditStore.editedSegments(dir: dir, segments: doc.segments)
        var out: [SearchSnippet] = []
        for seg in segments {
            let tokens = Set(tokenize(seg.text))
            guard terms.contains(where: { tokens.contains($0) }) else { continue }
            out.append(SearchSnippet(timestamp: DocumentBuilder.timestamp(seg.start), text: seg.text))
            if out.count >= limit { break }
        }
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
        // `DocumentBuilder` emits a fenced code block for exactly one thing — a frame's on-slide
        // text — so a line inside a fence came from a slide, and one outside it came from speech.
        // That is what lets a hit say which it was without a second index.
        var insideSlideText = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { insideSlideText.toggle(); continue }
            if t.isEmpty { continue }
            if let ts = SessionStore.firstTimestamp(in: t) { currentTS = ts }
            // Skip structural lines (header, image, details/summary).
            if t.hasPrefix("#") || t == "---" || t.hasPrefix("- **") || t.hasPrefix("![")
                || t.hasPrefix("<details") || t.hasPrefix("</details") || t.hasPrefix("<summary") { continue }
            if Set(tokenize(t)).isDisjoint(with: termSet) { continue }
            let clean = SessionStore.stripLeadingTimestamp(stripMarkup(t))
            if clean.isEmpty { continue }
            snippets.append(SearchSnippet(timestamp: currentTS, text: String(clean.prefix(180)),
                                          isSlide: insideSlideText))
            if snippets.count >= limit { break }
        }
        return snippets
    }

    private static func stripMarkup(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    // MARK: - Persistence

    /// The session's freshness stamp: the LATER of `transcript.md` and `edits.json`.
    ///
    /// Both, because both feed the index. Watching only the transcript would make `rebuildFromDisk`
    /// skip an edited session as "still fresh" forever — the corrections would be indexed by the
    /// `index(sessionDir:)` call that follows an edit and then silently lost at the next launch,
    /// which is a worse failure than never indexing them at all, because it is intermittent.
    private func transcriptMTime(_ dir: URL) -> Date {
        func mtime(_ name: String) -> Date? {
            (try? dir.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        guard let transcript = mtime("transcript.md") else { return Date() }
        guard let edits = mtime(EditStore.fileName) else { return transcript }
        return max(transcript, edits)
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
