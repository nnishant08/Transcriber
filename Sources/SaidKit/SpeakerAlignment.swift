import Foundation

/// A contiguous span of one speaker's speech (seconds from session T0), with the diarizer's raw
/// cluster id normalized to a stable 1-based slot in first-appearance order.
public struct SpeakerTurn: Sendable, Equatable {
    public var speaker: Int
    public var start: Double
    public var end: Double
}

/// Pure functions joining diarizer speaker turns onto transcript segments. No models, no I/O —
/// fully unit-testable (`--selftest-align`).
public enum SpeakerAlignment {

    /// Normalize raw diarizer cluster ids to stable 1-based `Int` slots in FIRST-APPEARANCE order
    /// (after sorting by start time), so labels read "Speaker 1, Speaker 2…" in the order they
    /// first speak — deterministic and testable regardless of the raw id strings.
    public static func normalize(_ raw: [(id: String, start: Double, end: Double)]) -> [SpeakerTurn] {
        normalizeWithSlots(raw).turns
    }

    /// `normalize`, plus the raw-id → slot mapping it derived.
    ///
    /// Phase 3 needs the mapping as well as the turns: cross-session voiceprints group the
    /// diarizer's per-segment embeddings by the SAME slot the transcript is labelled with, and
    /// re-deriving that mapping in a second place is exactly how two rules drift apart. One
    /// implementation, two return values.
    public static func normalizeWithSlots(_ raw: [(id: String, start: Double, end: Double)])
        -> (turns: [SpeakerTurn], slotForID: [String: Int]) {
        let sorted = raw.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        var slots: [String: Int] = [:]
        var turns: [SpeakerTurn] = []
        for r in sorted {
            let slot: Int
            if let existing = slots[r.id] {
                slot = existing
            } else {
                slot = slots.count + 1
                slots[r.id] = slot
            }
            turns.append(SpeakerTurn(speaker: slot, start: r.start, end: r.end))
        }
        return (turns, slots)
    }

    // MARK: - Tuning

    /// The shortest run of same-speaker words that may become its own segment.
    ///
    /// Diarizer boundaries are not exact, so the word or two either side of a real turn change is
    /// routinely attributed to the wrong person. Splitting on a single stray word would therefore
    /// manufacture a one-word "Speaker 2:" line in the middle of someone else's sentence far more
    /// often than it would catch a real interjection. Three words is roughly the shortest thing a
    /// person actually says as a turn ("no, that's wrong"), so runs shorter than this are absorbed
    /// into the neighbouring run instead of splitting the segment.
    ///
    /// Tuned, not derived — see `PHASE3-REPORT.md`. Raising it makes splits rarer and safer;
    /// lowering it catches faster interruptions at the cost of noise.
    public static let minimumRunWords = 3

    // MARK: - Assignment

    /// Assign speakers to `segments` from diarizer `turns`.
    ///
    /// Two paths, chosen **per segment** by whether it carries usable word timings:
    ///
    /// - **No word timings** → `assignWholeSegment`, which is the pre-Phase-3 implementation
    ///   verbatim. Every legacy session, and every session an engine transcribed without word
    ///   timings, therefore produces byte-identical output to before. That guarantee is structural —
    ///   it is the same function, not a reimplementation that happens to agree — which is a stronger
    ///   claim than any fixture could make, and `--selftest-align` asserts it against a fixture too.
    ///
    /// - **Word timings present** → `assignByWord`, which can split a segment where the speaker
    ///   changes mid-sentence. That is exactly the case whole-segment alignment got silently wrong:
    ///   on interruptions and fast back-and-forth — the cases where diarization is most valuable —
    ///   the whole segment went to whoever held it longest and the other person's words were
    ///   attributed to them with no indication anything was lost.
    public static func assign(segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }
        guard segments.contains(where: { $0.hasWordTimings }) else {
            return assignWholeSegment(segments: segments, turns: turns)   // the legacy path, untouched
        }
        return segments.flatMap { seg -> [TranscriptSegment] in
            guard seg.validWords != nil else {
                return assignWholeSegment(segments: [seg], turns: turns)
            }
            return assignByWord(segment: seg, turns: turns)
        }
    }

    /// **The pre-Phase-3 algorithm, unchanged.**
    ///
    /// Assign each segment the speaker of the turn with MAXIMUM temporal overlap with
    /// `[seg.start, seg.end]`. Zero overlap with every turn → the turn with the nearest midpoint.
    /// Deterministic on ties (the earlier turn wins). Never drops, re-times, or merges a segment —
    /// every `[mm:ss]` anchor survives untouched.
    ///
    /// Kept as its own function rather than folded into the new one on purpose: it is the reference
    /// behaviour that the legacy guarantee is stated against, and it is what `--selftest-align`
    /// compares the dispatcher's output to.
    public static func assignWholeSegment(segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }
        return segments.map { seg in
            var out = seg
            out.speaker = speaker(forStart: seg.start, end: seg.end, turns: turns)
            return out
        }
    }

    /// Max-overlap with nearest-midpoint fallback, for one time span. The whole-segment and
    /// per-word paths share it, so a one-word segment and a one-word span resolve identically.
    static func speaker(forStart start: Double, end: Double, turns: [SpeakerTurn]) -> Int? {
        guard !turns.isEmpty else { return nil }
        var bestOverlap = 0.0
        var bestSpeaker: Int? = nil
        for t in turns {
            let overlap = min(end, t.end) - max(start, t.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = t.speaker
            }
        }
        if let bestSpeaker { return bestSpeaker }
        // No overlap at all (e.g. a segment inside a diarizer silence gap) → nearest midpoint.
        let mid = (start + end) / 2
        var bestDist = Double.infinity
        var nearest = turns[0].speaker
        for t in turns {
            let dist = abs((t.start + t.end) / 2 - mid)
            if dist < bestDist { bestDist = dist; nearest = t.speaker }
        }
        return nearest
    }

    // MARK: - Word-boundary splitting

    /// One segment → one or more, split where the speaker changes at a word boundary.
    ///
    /// Falls back to whole-segment assignment — never to a guess — whenever the split cannot be made
    /// safely: one speaker throughout, every run too short to be a real turn, or the words cannot be
    /// located in the segment's own text (which would mean cutting the string at an offset that does
    /// not correspond to the boundary).
    static func assignByWord(segment: TranscriptSegment, turns: [SpeakerTurn]) -> [TranscriptSegment] {
        guard let words = segment.validWords, !words.isEmpty else {
            return assignWholeSegment(segments: [segment], turns: turns)
        }

        let perWord = words.map { speaker(forStart: $0.start, end: $0.end, turns: turns) }
        var runs = self.runs(of: perWord)
        runs = absorbShortRuns(runs, totalWords: words.count)

        guard runs.count > 1 else {
            // One speaker across the whole segment: the ordinary case. Assign and leave the segment
            // whole, so a normal two-person conversation is not shredded into per-turn fragments.
            var out = segment
            out.speaker = runs.first?.speaker ?? speaker(forStart: segment.start, end: segment.end, turns: turns)
            return [out]
        }

        // Cutting the TEXT, not just the words: rebuilding each part by joining its words would
        // discard the segment's real punctuation and spacing. Locating each word in the original
        // string keeps every character the engine wrote.
        guard let ranges = wordRanges(of: words, in: segment.text) else {
            var out = segment
            out.speaker = speaker(forStart: segment.start, end: segment.end, turns: turns)
            return [out]
        }

        var out: [TranscriptSegment] = []
        for (i, run) in runs.enumerated() {
            let slice = Array(words[run.range])
            guard let first = slice.first, let last = slice.last else { continue }
            let lower = ranges[run.range.lowerBound].lowerBound
            // Each part runs up to where the NEXT part's first word begins — not to where its own
            // last word ends — so the punctuation and spacing between them stays with the earlier
            // part instead of falling into the gap and being lost. The final part runs to the end of
            // the string for the same reason.
            let upper = (i == runs.count - 1) ? segment.text.endIndex
                                              : ranges[runs[i + 1].range.lowerBound].lowerBound
            guard lower <= upper else { continue }
            let text = String(segment.text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append(TranscriptSegment(start: first.start,
                                         end: max(last.end, first.start),
                                         text: text,
                                         speaker: run.speaker,
                                         cleanedText: nil,
                                         redactedText: nil,
                                         words: slice))
        }
        // A split that produced nothing usable must not lose the segment.
        return out.isEmpty ? assignWholeSegment(segments: [segment], turns: turns) : out
    }

    struct Run: Equatable {
        var speaker: Int?
        var range: Range<Int>
        var count: Int { range.count }
    }

    /// Consecutive equal values → runs.
    static func runs(of speakers: [Int?]) -> [Run] {
        var out: [Run] = []
        var i = 0
        while i < speakers.count {
            var j = i + 1
            while j < speakers.count, speakers[j] == speakers[i] { j += 1 }
            out.append(Run(speaker: speakers[i], range: i..<j))
            i = j
        }
        return out
    }

    /// Merge runs shorter than `minimumRunWords` into a neighbour, repeatedly, until every run is
    /// long enough or only one remains.
    ///
    /// A short run joins the LONGER of its neighbours, which is the conservative choice: it keeps a
    /// stray word with whoever was clearly talking rather than letting it anchor a spurious turn.
    static func absorbShortRuns(_ input: [Run], totalWords: Int) -> [Run] {
        var runs = input
        while runs.count > 1 {
            guard let i = runs.firstIndex(where: { $0.count < minimumRunWords }) else { break }
            let target: Int
            if i == 0 { target = 1 }
            else if i == runs.count - 1 { target = i - 1 }
            else { target = runs[i - 1].count >= runs[i + 1].count ? i - 1 : i + 1 }

            let lower = min(runs[i].range.lowerBound, runs[target].range.lowerBound)
            let upper = max(runs[i].range.upperBound, runs[target].range.upperBound)
            let merged = Run(speaker: runs[target].speaker, range: lower..<upper)
            let (lo, hi) = (min(i, target), max(i, target))
            runs.replaceSubrange(lo...hi, with: [merged])
        }
        return runs
    }

    /// Locate each word in the segment's text, in order. `nil` if any word cannot be found — which
    /// means the words and the text disagree, and cutting the string would be guesswork.
    static func wordRanges(of words: [WordTiming], in text: String) -> [Range<String.Index>]? {
        var out: [Range<String.Index>] = []
        var cursor = text.startIndex
        for w in words {
            let needle = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return nil }
            guard let r = text.range(of: needle, range: cursor..<text.endIndex) else { return nil }
            out.append(r)
            cursor = r.upperBound
        }
        return out
    }
}
