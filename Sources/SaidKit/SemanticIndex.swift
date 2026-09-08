import Foundation

/// One embedded passage of a session, with the `[mm:ss]` anchor it came from.
public struct SemanticChunk: Codable, Sendable, Equatable {
    public var sessionPath: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var vector: [Float]

    public init(sessionPath: String, start: TimeInterval, end: TimeInterval,
                text: String, vector: [Float]) {
        self.sessionPath = sessionPath
        self.start = start
        self.end = end
        self.text = text
        self.vector = vector
    }

    public var timestamp: String { DocumentBuilder.timestamp(start) }
}

/// A semantic hit: a chunk and how close it was.
public struct SemanticHit: Sendable, Equatable {
    public let chunk: SemanticChunk
    public let similarity: Float

    public init(chunk: SemanticChunk, similarity: Float) {
        self.chunk = chunk
        self.similarity = similarity
    }
}

// MARK: - Chunking

/// Cuts a transcript into passages worth embedding. Pure — `--selftest-semantic` asserts the
/// boundaries and the times without loading a model.
public enum SemanticChunker {

    /// Roughly how many words go in a chunk.
    ///
    /// About 300 tokens' worth. Small enough that a hit points at something specific — the whole
    /// value of retrieval is landing on the passage, not the session — and large enough to carry the
    /// context that makes an embedding mean anything. A single transcript line is usually too short
    /// to embed usefully; a whole session is one vague vector.
    public static let targetWords = 220
    /// Words repeated from the previous chunk, so a sentence spanning a boundary is retrievable from
    /// either side rather than falling into the crack between them.
    public static let overlapWords = 40

    /// Segments → chunks.
    ///
    /// Chunks never cross a segment boundary mid-segment, so every chunk's start time is a real
    /// `[mm:ss]` anchor that click-to-seek already knows how to handle. Where `validWords` is
    /// available the END time is the last word's, which is tighter than the segment's; where it is
    /// not, the segment's own bounds are used and the chunk is simply coarser. That is the whole
    /// `validWords` discipline in miniature: better when present, correct when absent.
    public static func chunks(segments: [TranscriptSegment], sessionPath: String) -> [SemanticChunk] {
        let usable = segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return [] }

        var out: [SemanticChunk] = []
        var current: [TranscriptSegment] = []
        var wordCount = 0
        // Whether a real segment has arrived since the last flush.
        //
        // The tail must not re-emit a chunk when `current` holds nothing but the carry-over suffix
        // the previous flush already wrote — and TIMES CANNOT ANSWER THAT QUESTION. A chunk's end is
        // the last WORD's end, which is strictly earlier than the segment's own end whenever word
        // timings are present, so a bounds comparison reports "not covered" for precisely the
        // segments it just wrote, and the tail emits a duplicate that is a strict subset of the
        // chunk before it. Word timings are what Phase 3 added, so that failure would have been
        // invisible on legacy sessions and universal on Parakeet ones.
        var appendedSinceFlush = false

        func flush(carryOver: Bool) {
            guard let first = current.first, let last = current.last else { return }
            appendedSinceFlush = false
            let text = current.map { $0.text.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            guard !text.isEmpty else { current = []; wordCount = 0; return }
            let end = last.validWords?.last?.end ?? last.end
            out.append(SemanticChunk(sessionPath: sessionPath,
                                     start: first.validWords?.first?.start ?? first.start,
                                     end: max(end, first.start),
                                     text: text, vector: []))
            if carryOver {
                // Keep whole trailing segments as the overlap rather than slicing text: an overlap
                // that begins mid-sentence embeds worse than one that begins at a real boundary.
                var carry: [TranscriptSegment] = []
                var carried = 0
                for seg in current.reversed() {
                    let n = words(in: seg.text)
                    if carried + n > overlapWords, !carry.isEmpty { break }
                    carry.insert(seg, at: 0)
                    carried += n
                }
                current = carry
                wordCount = carried
            } else {
                current = []
                wordCount = 0
            }
        }

        for seg in usable {
            current.append(seg)
            appendedSinceFlush = true
            wordCount += words(in: seg.text)
            if wordCount >= targetWords { flush(carryOver: true) }
        }
        // The tail. `carryOver: false` so the overlap logic cannot re-emit what it just wrote.
        if !current.isEmpty, appendedSinceFlush { flush(carryOver: false) }
        return out
    }

    static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}

// MARK: - The index

/// Vector search over the corpus, mirroring `SearchIndex`'s discipline exactly: a cache under
/// Application Support for a fast cold start, disk mtimes as the source of truth, an `NSLock`,
/// `Sendable`, and rebuild-from-disk validation.
///
/// **OFF by default.** Nothing here runs, no model is fetched and no file is written until the user
/// turns it on. Keyword search is completely unchanged when it is off — the fusion in
/// `HybridRetrieval` degenerates to "the keyword ranking" when there are no semantic hits.
///
/// **When at-rest encryption is ON the index is in-memory only**, exactly mirroring the rule
/// `SearchIndex` already follows. An embedding is a lossy but real reconstruction of the passage it
/// came from; writing vectors in plaintext beside an encrypted transcript would quietly undo the
/// thing encryption is for.
public final class SemanticIndex: @unchecked Sendable {

    public static let shared = SemanticIndex(cacheURL: SemanticIndex.defaultCacheURL)

    /// OFF by default, opt-in, with an explicit model download the user consents to.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "semanticSearchEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "semanticSearchEnabled") }
    }

    private struct Entry: Codable {
        var path: String
        var mtime: Date
        var modelID: String
        var dimension: Int
        var chunks: [SemanticChunk]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let cacheURL: URL
    private let embedder: any EmbeddingProvider

    public init(cacheURL: URL, embedder: any EmbeddingProvider = AppleContextualEmbedder()) {
        self.cacheURL = cacheURL
        self.embedder = embedder
        loadCache()
    }

    public var indexedSessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public var indexedChunkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.chunks.count }
    }

    // MARK: Building

    /// Embed one session. No-op when the feature is off.
    public func index(sessionDir dir: URL) async {
        guard Self.isEnabled else { return }
        do { try await embedder.prepare() } catch {
            NSLog("[Semantic] model unavailable (\(error)); skipping \(dir.lastPathComponent)")
            return
        }
        guard await embedder.isReady else { return }

        // Embed the EDITED view: a user's corrections are what they meant, and a question about
        // "SQL" should reach a passage they fixed from "sequel".
        guard let doc = DocumentBuilder.readSession(dir) else { return }
        let segments = EditStore.editedSegments(dir: dir, segments: doc.segments)
        let chunks = SemanticChunker.chunks(segments: segments, sessionPath: dir.path)
        guard !chunks.isEmpty else { return }

        var embedded: [SemanticChunk] = []
        for var chunk in chunks {
            guard let v = await embedder.embed(chunk.text) else { continue }
            chunk.vector = v
            embedded.append(chunk)
        }
        guard !embedded.isEmpty else { return }

        let entry = Entry(path: dir.path, mtime: Self.transcriptMTime(dir),
                          modelID: await embedder.identifier,
                          dimension: await embedder.dimension, chunks: embedded)
        lock.lock(); entries[dir.path] = entry; lock.unlock()
        saveCache()
    }

    public func remove(dir: URL) {
        lock.lock(); entries[dir.path] = nil; lock.unlock()
        saveCache()
    }

    /// Reconcile with disk. Re-embeds any session whose transcript changed, drops vanished ones, and
    /// — importantly — drops entries embedded by a DIFFERENT model, because comparing vectors from
    /// two embedding spaces produces confident nonsense.
    ///
    /// `progress` reports (done, total) so a long first build can be shown and cancelled.
    public func rebuildFromDisk(root: URL = SessionStore.root,
                                progress: (@Sendable (Int, Int) -> Void)? = nil) async {
        guard Self.isEnabled else { return }
        do { try await embedder.prepare() } catch { return }
        let modelID = await embedder.identifier

        let dirs = SessionStore.sessionDirectoryURLs(root: root)
        let present = Set(dirs.map { $0.path })
        lock.lock()
        entries = entries.filter { present.contains($0.key) && $0.value.modelID == modelID }
        lock.unlock()

        var done = 0
        for dir in dirs {
            if Task.isCancelled { break }
            let mtime = Self.transcriptMTime(dir)
            lock.lock(); let cached = entries[dir.path]; lock.unlock()
            if let cached, abs(cached.mtime.timeIntervalSince(mtime)) < 0.5 {
                done += 1; progress?(done, dirs.count); continue
            }
            await index(sessionDir: dir)
            done += 1
            progress?(done, dirs.count)
        }
        saveCache()
    }

    // MARK: Query

    /// Nearest chunks to `query`, best first. Empty when the feature is off or the model is absent —
    /// never an error, because every caller has a keyword ranking to fall back on.
    public func search(_ query: String, limit: Int = 12) async -> [SemanticHit] {
        guard Self.isEnabled else { return [] }
        if await !embedder.isReady {
            // A failure here is not an error condition for the caller: every consumer of semantic
            // search has a keyword ranking to fall back on, and returning nothing degrades to
            // exactly the pre-Phase-3 behaviour.
            do { try await embedder.prepare() } catch { return [] }
        }
        guard let q = await embedder.embed(query) else { return [] }

        lock.lock(); let snapshot = entries; lock.unlock()
        var hits: [SemanticHit] = []
        for (_, e) in snapshot where e.dimension == q.count {
            for chunk in e.chunks {
                hits.append(SemanticHit(chunk: chunk, similarity: VectorMath.dot(q, chunk.vector)))
            }
        }
        hits.sort { $0.similarity > $1.similarity }
        return Array(hits.prefix(limit))
    }

    // MARK: Persistence

    private static func transcriptMTime(_ dir: URL) -> Date {
        (try? dir.appendingPathComponent("transcript.md")
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
    }

    private func loadCache() {
        guard !SessionIO.isEncryptionEnabled else { return }   // in-memory only when encrypted
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

    /// Delete the on-disk cache. Called when the feature is switched off, so turning it off actually
    /// removes the vectors rather than merely ignoring them.
    public func purgeCache() {
        lock.lock(); entries = [:]; lock.unlock()
        try? FileManager.default.removeItem(at: cacheURL)
    }

    public static var defaultCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Said", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("semantic-index.json")
    }
}

// MARK: - Hybrid retrieval

/// Fuses keyword and semantic rankings.
///
/// **Why fuse rather than replace.** Keyword search is the ceiling on every AI feature Said already
/// ships: ask "what did we decide about pricing" against a transcript that says "the number we're
/// going to charge" and retrieval returns nothing, then the model answers confidently from an empty
/// context. Embeddings fix exactly that. But they are *worse* than keyword at the thing keyword is
/// perfect at — an exact name, a case number, a drug, a version string — where a near-miss is not a
/// near-answer. Keeping both and fusing is the only option that does not trade one failure for the
/// other.
public enum HybridRetrieval {

    /// Reciprocal Rank Fusion's smoothing constant.
    ///
    /// 60 is the value from the original RRF paper and the de-facto default. It matters less than it
    /// looks: it flattens the difference between ranks 1 and 2 so that a result ranked highly by
    /// BOTH retrievers beats one ranked first by either alone — which is precisely the behaviour
    /// wanted here, since agreement between a lexical and a semantic signal is strong evidence.
    ///
    /// **RRF was chosen over a weighted score blend deliberately**: blending requires the two
    /// scores to be comparable, and they are not — `SearchIndex` returns unbounded match counts and
    /// `SemanticIndex` returns cosine similarities in [-1, 1]. Normalising them into agreement is
    /// exactly the kind of tuning that produces a hybrid ranker WORSE than the keyword search it
    /// replaced (§9.4). Rank fusion needs no such calibration.
    public static let rrfK = 60.0

    /// Fuse a keyword ranking and a semantic ranking into one session ordering.
    ///
    /// With semantic search off, `semantic` is empty and the output is the keyword ranking in its
    /// original order — the no-op path, asserted by `--selftest-semantic`.
    public static func fuse(keyword: [SessionHit], semantic: [SemanticHit], limit: Int = 8) -> [SessionHit] {
        guard !semantic.isEmpty else { return Array(keyword.prefix(limit)) }

        var score: [String: Double] = [:]
        for (i, hit) in keyword.enumerated() {
            score[hit.dir.path, default: 0] += 1.0 / (rrfK + Double(i + 1))
        }
        // A session's semantic rank is that of its BEST chunk. Letting several chunks from one
        // session each contribute would rank a long session above a relevant one.
        var seen = Set<String>()
        var semanticRank = 0
        for hit in semantic {
            guard seen.insert(hit.chunk.sessionPath).inserted else { continue }
            semanticRank += 1
            score[hit.chunk.sessionPath, default: 0] += 1.0 / (rrfK + Double(semanticRank))
        }

        // Only sessions the keyword index knows about can be RETURNED, because a `SessionHit`
        // carries the snippets and metadata the UI renders. A session found only semantically is
        // therefore surfaced by attaching its semantic passage as a snippet — see `snippets(for:)`.
        var byPath: [String: SessionHit] = [:]
        for h in keyword { byPath[h.dir.path] = h }

        return score.sorted { $0.value > $1.value }
            .compactMap { byPath[$0.key] }
            .prefix(limit)
            .map { $0 }
    }

    /// Sessions the semantic index found that keyword search missed entirely — the case the whole
    /// wave exists for. Returned separately so the caller can build `SessionHit`s for them with the
    /// matching passage as the snippet.
    public static func semanticOnlyPaths(keyword: [SessionHit], semantic: [SemanticHit]) -> [String] {
        let known = Set(keyword.map(\.dir.path))
        var out: [String] = []
        var seen = Set<String>()
        for hit in semantic where !known.contains(hit.chunk.sessionPath) {
            if seen.insert(hit.chunk.sessionPath).inserted { out.append(hit.chunk.sessionPath) }
        }
        return out
    }
}
