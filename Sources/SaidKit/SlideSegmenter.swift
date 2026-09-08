import Foundation

/// A stretch of the timeline during which one slide was on screen.
///
/// **Derived from `SessionDoc.frames`, never a second source of truth.** Frames are what the phone
/// captured; a span is a reading of them. `writeSession` recomputes and caches these on every write,
/// and any reader that finds no cache derives them on the spot — so the two can never disagree about
/// anything except how recently they were computed.
public struct SlideSpan: Codable, Sendable, Equatable {
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    /// The frame chosen to represent the whole span.
    public var representativeImagePath: String
    /// The OCR text for the span — from the representative frame, so it is the cleanest reading
    /// available rather than a concatenation of several noisy ones.
    public var text: String?
    /// How many captured frames collapsed into this span. `1` is normal for a slide photographed
    /// once; a large number means someone left the camera running on a static slide.
    public var frameCount: Int

    public init(startTime: TimeInterval, endTime: TimeInterval, representativeImagePath: String,
                text: String? = nil, frameCount: Int = 1) {
        self.startTime = startTime
        self.endTime = endTime
        self.representativeImagePath = representativeImagePath
        self.text = text
        self.frameCount = frameCount
    }

    public var duration: TimeInterval { max(0, endTime - startTime) }
}

/// Collapses near-identical consecutive frames into slide spans.
///
/// **What was actually missing.** OCR text already reached the search index before Phase 3 —
/// `DocumentBuilder` writes it into `transcript.md` and `SearchIndex` tokenises that file, so a
/// phrase that only ever appeared on a slide already found the session. What was missing is
/// everything that makes the result *usable*: a slide left up for ten minutes floods the index with
/// the same text over and over, there is no notion of "slide 4 spanned 12:03–18:40" (which is the
/// unit a person actually wants), and a hit cannot say it came from a slide rather than from speech.
/// This type supplies the first two; `SearchIndex` supplies the third.
///
/// Pure — no images are opened, no Vision call is made. Similarity is judged on the OCR TEXT, which
/// is both far cheaper than pixel comparison and a better proxy for the question being asked: two
/// photographs of the same slide from slightly different angles are the same slide.
public enum SlideSegmenter {

    /// How much of two frames' OCR text must overlap for them to be the same slide.
    ///
    /// Measured as the **overlap coefficient** — the intersection over the SMALLER word set — not
    /// Jaccard. That choice is the whole correctness of this type, so it is worth the paragraph:
    ///
    /// Jaccard divides by the UNION, so it charges a reading for every word the OTHER reading
    /// happened to pick up. Two photographs of one five-word title where Vision reads "segments"
    /// once and "segment" the next time score 4/6 = 0.67 and are declared different slides. The
    /// penalty scales with how little text is on the slide, so it is worst exactly where slides are
    /// shortest — titles and section dividers, the ones most likely to stay up the longest. The
    /// overlap coefficient asks the question that actually matters — "is one reading essentially
    /// contained in the other?" — and scores that pair 4/5 = 0.8.
    ///
    /// The failure mode this OPENS is a small set swallowed by a large one: a slide reading
    /// {agenda} is fully contained in {agenda, methodology, results, timeline} and would merge at
    /// 1.0. `minimumSizeRatio` closes it. Two photographs of one slide read roughly the same AMOUNT
    /// of text; a reading a quarter the length of its neighbour is a different slide, not a blurrier
    /// picture of the same one.
    ///
    /// The bias stays where the doc comment always claimed it was — toward NOT collapsing, because
    /// wrongly splitting one slide costs a duplicate card while wrongly merging two costs a slide
    /// that has vanished from the timeline entirely.
    ///
    /// Tuned, not derived — see `PHASE3-REPORT.md`.
    public static let similarityThreshold = 0.75

    /// The smaller word set must be at least this fraction of the larger for the overlap coefficient
    /// to be trusted at all. See `similarityThreshold` for why.
    public static let minimumSizeRatio = 0.5

    /// Frames → spans, in time order.
    ///
    /// - Parameter sessionDuration: used to close the last span. When unknown, the last span is
    ///   given the same length as the median of the others, and failing that a nominal minute —
    ///   never zero, because a zero-length span cannot be clicked.
    public static func spans(frames: [FrameEvent], sessionDuration: TimeInterval? = nil) -> [SlideSpan] {
        let ordered = frames.sorted { $0.time < $1.time }
        guard !ordered.isEmpty else { return [] }

        // 1. Group consecutive frames whose OCR text says they are the same slide.
        var groups: [[FrameEvent]] = []
        for frame in ordered {
            if let last = groups.last?.last, isSameSlide(last, frame) {
                groups[groups.count - 1].append(frame)
            } else {
                groups.append([frame])
            }
        }

        // 2. Each group becomes a span running until the next group starts.
        var out: [SlideSpan] = []
        for (i, group) in groups.enumerated() {
            guard let first = group.first else { continue }
            let representative = clearest(in: group)
            let end: TimeInterval
            if i + 1 < groups.count, let next = groups[i + 1].first {
                end = next.time
            } else if let sessionDuration, sessionDuration > first.time {
                end = sessionDuration
            } else {
                end = first.time + fallbackTailLength(groups: groups)
            }
            out.append(SlideSpan(startTime: first.time,
                                 endTime: max(end, first.time),
                                 representativeImagePath: representative.imagePath,
                                 text: representative.text,
                                 frameCount: group.count))
        }
        return out
    }

    /// Two frames show the same slide when their OCR text overlaps enough.
    ///
    /// A frame with NO text is never merged with anything — not even another textless frame. Two
    /// photographs with nothing legible on them are not evidence of being the same slide, and
    /// merging them would silently drop one from the timeline. Being wrong in the other direction
    /// only costs an extra card.
    static func isSameSlide(_ a: FrameEvent, _ b: FrameEvent) -> Bool {
        guard let ta = normalizedWords(a.text), !ta.isEmpty,
              let tb = normalizedWords(b.text), !tb.isEmpty else { return false }
        let ratio = Double(min(ta.count, tb.count)) / Double(max(ta.count, tb.count))
        guard ratio >= minimumSizeRatio else { return false }
        return overlap(ta, tb) >= similarityThreshold
    }

    /// The frame that best represents a group.
    ///
    /// "Clearest" is approximated by the MOST TEXT Vision managed to read. Without opening the
    /// images there is no sharpness measure available, and word count is a genuinely good proxy: a
    /// blurred or angled photograph of a slide loses words, it does not gain them.
    static func clearest(in group: [FrameEvent]) -> FrameEvent {
        group.max { lhs, rhs in
            (normalizedWords(lhs.text)?.count ?? 0) < (normalizedWords(rhs.text)?.count ?? 0)
        } ?? group[0]
    }

    static func normalizedWords(_ text: String?) -> Set<String>? {
        guard let text else { return nil }
        let words = SearchIndex.tokenize(text)
        return words.isEmpty ? nil : Set(words)
    }

    /// Overlap coefficient: intersection over the SMALLER set. Divides by the smaller side on
    /// purpose — see `similarityThreshold`. Guarded by `minimumSizeRatio` at the call site, which is
    /// what stops a short reading from being swallowed by a long unrelated one.
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let smaller = min(a.count, b.count)
        guard smaller > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(smaller)
    }

    /// A sensible length for the final span when the session duration is unknown: the median gap
    /// between the spans we do know about, or a minute.
    private static func fallbackTailLength(groups: [[FrameEvent]]) -> TimeInterval {
        let starts = groups.compactMap { $0.first?.time }
        guard starts.count > 1 else { return 60 }
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return 60 }
        return gaps[gaps.count / 2]
    }
}
