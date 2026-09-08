import Foundation

// MARK: - The edit record

/// One correction a user made to a transcript.
///
/// **An overlay, never a mutation.** The same rule that governs `cleanedText` and `redactedText`
/// governs this: `transcript.md` is the verbatim record of what the recording contained, and a user
/// fixing "sequel" to "SQL" is stating what they *meant*, not rewriting what was said. Edits live in
/// their own `edits.json` and are applied on read.
public struct TranscriptEdit: Codable, Sendable, Equatable {
    /// Index into `SessionDoc.segments`.
    public let segmentIndex: Int
    /// Index into that segment's `validWords`, or `nil` for a whole-segment edit — which is what a
    /// legacy session with no word timings gets, so **every** session is editable, just at a coarser
    /// granularity.
    public let wordIndex: Int?
    /// What the text was. This is the anchor, not decoration: an edit only applies when what is
    /// there still matches, which is what makes the overlay idempotent and what stops a stale edit
    /// from corrupting a re-transcribed session.
    public let original: String
    public let corrected: String
    public let at: Date

    public init(segmentIndex: Int, wordIndex: Int?, original: String, corrected: String, at: Date) {
        self.segmentIndex = segmentIndex
        self.wordIndex = wordIndex
        self.original = original
        self.corrected = corrected
        self.at = at
    }

    public var isWholeSegment: Bool { wordIndex == nil }
}

/// Why an edit did not apply. Surfaced to the user rather than swallowed — an edit that silently
/// stops taking effect is worse than one that says it has come unanchored.
public enum EditAnchorFailure: Sendable, Equatable {
    case segmentOutOfRange
    case wordOutOfRange
    case textChanged
}

// MARK: - Application

/// Applies the edit overlay to a segment list. Pure — no I/O, no dates, no globals — so
/// `--selftest-edit` asserts every rule headlessly.
public enum EditOverlay {

    /// Apply `edits` (oldest first) to `segments`.
    ///
    /// **Idempotent by construction, not by convention.** Each edit only fires when the text it
    /// names is still present at the position it names; after it has been applied that text is gone,
    /// so a second pass finds nothing to do. That one guard also does the work of three other rules:
    /// a re-transcription that reshaped the segments cannot be corrupted by stale edits, applying
    /// the same file twice is safe, and a user who edits the same word twice gets both edits in
    /// order (the second one's `original` is the first one's `corrected`).
    public static func apply(segments: [TranscriptSegment], edits: [TranscriptEdit]) -> [TranscriptSegment] {
        guard !edits.isEmpty else { return segments }
        var out = segments
        for edit in edits.sorted(by: { $0.at < $1.at }) {
            guard out.indices.contains(edit.segmentIndex) else { continue }
            if let updated = applyOne(edit, to: out[edit.segmentIndex]) {
                out[edit.segmentIndex] = updated
            }
        }
        return out
    }

    /// One edit against one segment. `nil` when it does not anchor.
    private static func applyOne(_ edit: TranscriptEdit, to segment: TranscriptSegment) -> TranscriptSegment? {
        var seg = segment

        guard let wordIndex = edit.wordIndex else {
            // Whole-segment edit (a legacy session, or a line the user rewrote outright).
            guard seg.text == edit.original else { return nil }
            seg.text = edit.corrected
            // The stored words no longer describe this text. Dropping them is the honest move:
            // `validWords` would otherwise hand a downstream consumer word timings for words that
            // are no longer in the segment.
            seg.words = nil
            return seg
        }

        guard let words = seg.validWords, words.indices.contains(wordIndex) else { return nil }
        guard words[wordIndex].text == edit.original else { return nil }   // already applied, or moved

        // Replace in the TEXT by occurrence rather than by rebuilding it from the word array.
        // Rebuilding would join words with single spaces and quietly discard the segment's real
        // punctuation and spacing; substituting the right occurrence leaves every other character
        // exactly as the engine wrote it.
        let occurrence = words[..<wordIndex].reduce(0) { $0 + ($1.text == edit.original ? 1 : 0) }
        guard let replaced = replacing(occurrence: occurrence, of: edit.original,
                                       with: edit.corrected, in: seg.text) else { return nil }
        seg.text = replaced

        // Keep the word array in step, preserving the original word's timing — the correction is a
        // different spelling of the same sound, at the same moment.
        var updatedWords = words
        let old = updatedWords[wordIndex]
        updatedWords[wordIndex] = WordTiming(text: edit.corrected, start: old.start,
                                             end: old.end, confidence: old.confidence)
        seg.words = updatedWords
        return seg
    }

    /// Replace the `n`-th (0-based) whole-word occurrence of `needle` in `haystack`.
    ///
    /// Whole-word, so correcting "ion" in "an ion detector" cannot mangle "detection". Falls back to
    /// the single unambiguous occurrence when the indexed one is not found, and to `nil` when even
    /// that is ambiguous — an edit that cannot be placed precisely is skipped, never guessed at.
    static func replacing(occurrence n: Int, of needle: String, with replacement: String,
                          in haystack: String) -> String? {
        let ranges = wholeWordRanges(of: needle, in: haystack)
        let target: Range<String.Index>?
        if ranges.indices.contains(n) {
            target = ranges[n]
        } else if ranges.count == 1 {
            target = ranges[0]
        } else {
            target = nil
        }
        guard let target else { return nil }
        return haystack.replacingCharacters(in: target, with: replacement)
    }

    /// Every whole-word range of `needle` in `haystack`, in order.
    static func wholeWordRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let r = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let beforeOK = r.lowerBound == haystack.startIndex
                || !isWordCharacter(haystack[haystack.index(before: r.lowerBound)])
            let afterOK = r.upperBound == haystack.endIndex
                || !isWordCharacter(haystack[r.upperBound])
            if beforeOK && afterOK { out.append(r) }
            searchStart = r.upperBound
        }
        return out
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}"
    }

    /// Edits that no longer anchor, with the reason.
    ///
    /// Used by the Viewer to tell the user "3 of your edits no longer match this transcript" after a
    /// re-transcription reshapes the segments. They are **kept in the file, not deleted** (§6.5):
    /// silently discarding a user's corrections because a boundary moved would be the worst possible
    /// response to their having asked for a better transcript.
    public static func unanchored(_ edits: [TranscriptEdit],
                                  in segments: [TranscriptSegment]) -> [(TranscriptEdit, EditAnchorFailure)] {
        var applied = segments
        var failures: [(TranscriptEdit, EditAnchorFailure)] = []
        for edit in edits.sorted(by: { $0.at < $1.at }) {
            guard applied.indices.contains(edit.segmentIndex) else {
                failures.append((edit, .segmentOutOfRange)); continue
            }
            let seg = applied[edit.segmentIndex]
            if let wi = edit.wordIndex {
                guard let words = seg.validWords, words.indices.contains(wi) else {
                    failures.append((edit, .wordOutOfRange)); continue
                }
                if words[wi].text != edit.original { failures.append((edit, .textChanged)); continue }
            } else if seg.text != edit.original {
                failures.append((edit, .textChanged)); continue
            }
            if let updated = applyOne(edit, to: seg) { applied[edit.segmentIndex] = updated }
        }
        return failures
    }
}

// MARK: - Persistence

/// `edits.json` in the session folder, routed through `SessionIO` like every other text artifact —
/// so at-rest encryption covers a user's corrections exactly as it covers the transcript.
///
/// It lives in the session folder deliberately: `SessionBundle` stages the folder's whole contents
/// rather than an allow-list, so a `.said` carries edits across devices with no format change and no
/// `formatVersion` bump.
public enum EditStore {

    public static let fileName = "edits.json"

    public static func url(dir: URL) -> URL { dir.appendingPathComponent(fileName) }

    /// Read a session's edits. **Never throws and never makes a session unopenable** (§6.5): a
    /// corrupt file, or one written by a future build with a different shape, decodes to `[]` and
    /// the session opens as Verbatim.
    public static func read(dir: URL) -> [TranscriptEdit] {
        let u = url(dir: dir)
        guard FileManager.default.fileExists(atPath: u.path),
              let data = try? SessionIO.readData(u) else { return [] }
        guard let edits = try? JSONDecoder().decode([TranscriptEdit].self, from: data) else {
            NSLog("[Edits] \(u.lastPathComponent) could not be decoded; opening the session verbatim")
            return []
        }
        return edits
    }

    /// Write a session's edits atomically. An EMPTY list removes the file rather than leaving an
    /// empty one, so "this session has never been edited" and "this session's edits were all undone"
    /// look the same on disk — and a `.said` of an unedited session carries no extra file.
    public static func write(_ edits: [TranscriptEdit], dir: URL) throws {
        let u = url(dir: dir)
        guard !edits.isEmpty else {
            if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SessionIO.writeData(try encoder.encode(edits), to: u)
    }

    /// The session's segments with edits applied — the "Edited" view, and what export uses.
    public static func editedSegments(dir: URL, segments: [TranscriptSegment]) -> [TranscriptSegment] {
        EditOverlay.apply(segments: segments, edits: read(dir: dir))
    }
}

// MARK: - Correction memory

/// A correction the user has made more than once.
public struct LearnedCorrection: Codable, Sendable, Equatable, Identifiable {
    public var wrong: String
    public var right: String
    public var count: Int
    public var lastSeen: Date

    public var id: String { wrong.lowercased() + "→" + right.lowercased() }
}

/// What Said remembers from a user's corrections, and — much more importantly — what it refuses to
/// do with that memory.
///
/// **The rule: a learned correction is only ever promoted into the ASR vocabulary bias list. It is
/// NEVER applied as a string replacement to any transcript, past or future.**
///
/// This is not a stylistic preference, it is the difference between a feature and a data-loss bug.
/// Blind replacement means the user who once corrected "sequel" to "SQL" gets a corrupted transcript
/// the day they record a conversation about film sequels — and, because the transcript reads
/// fluently, they will never find out. Biasing the decoder toward "SQL" makes that word *more likely
/// to be recognised where it was actually said*; it cannot manufacture it where it was not.
///
/// Stored in Application Support rather than per-session: a learned term is about the user's
/// vocabulary, not about one recording.
public enum CorrectionMemory {

    /// How many times the same correction must be made before Said acts on it.
    ///
    /// Two, not one. A single correction is as likely to be a one-off — a misheard proper noun in a
    /// single meeting — as a standing term, and promoting on the first sighting would fill the bias
    /// list with noise, which degrades recognition for everything else.
    public static let promotionThreshold = 2

    public static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Said", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("learned-corrections.json")
    }

    /// Test hook — self-tests point the store at a temp dir instead of the user's real one.
    public static var overrideStoreURL: URL?
    private static var activeURL: URL { overrideStoreURL ?? storeURL }

    public static func all() -> [LearnedCorrection] {
        guard let data = try? Data(contentsOf: activeURL),
              let list = try? JSONDecoder().decode([LearnedCorrection].self, from: data) else { return [] }
        return list.sorted { $0.count != $1.count ? $0.count > $1.count : $0.lastSeen > $1.lastSeen }
    }

    private static func save(_ list: [LearnedCorrection]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: activeURL, options: .atomic)
    }

    /// Record that the user changed `original` to `corrected`.
    ///
    /// - Returns: the correction **if this observation promoted it** — i.e. it just reached the
    ///   threshold. The caller announces that ("Said will listen for *anastomosis* from now on")
    ///   rather than learning silently. Returns `nil` on the first sighting and on every sighting
    ///   after promotion, so the announcement happens exactly once.
    @discardableResult
    public static func record(original: String, corrected: String, now: Date = Date()) -> LearnedCorrection? {
        let wrong = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !right.isEmpty, wrong.lowercased() != right.lowercased() else { return nil }

        var list = all()
        if let i = list.firstIndex(where: { $0.wrong.lowercased() == wrong.lowercased()
                                         && $0.right.lowercased() == right.lowercased() }) {
            let wasPromoted = list[i].count >= promotionThreshold
            list[i].count += 1
            list[i].lastSeen = now
            save(list)
            return (!wasPromoted && list[i].count >= promotionThreshold) ? list[i] : nil
        }
        list.append(LearnedCorrection(wrong: wrong, right: right, count: 1, lastSeen: now))
        save(list)
        return promotionThreshold <= 1 ? list.last : nil
    }

    /// The promoted terms, for the vocabulary bias list. Only the CORRECT spelling is offered — the
    /// wrong one is what we are trying to stop the decoder producing.
    public static func promotedTerms() -> [String] {
        all().filter { $0.count >= promotionThreshold }.map(\.right)
    }

    public static func delete(_ correction: LearnedCorrection) {
        save(all().filter { $0.id != correction.id })
    }

    public static func clearAll() {
        try? FileManager.default.removeItem(at: activeURL)
    }
}
