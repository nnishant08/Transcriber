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
        return turns
    }

    /// Assign each segment the speaker of the turn with MAXIMUM temporal overlap with
    /// `[seg.start, seg.end]`. Zero overlap with every turn → the turn with the nearest midpoint.
    /// Deterministic on ties (the earlier turn wins). Never drops, re-times, or merges a segment —
    /// every `[mm:ss]` anchor survives untouched.
    public static func assign(segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }
        return segments.map { seg in
            var out = seg
            var bestOverlap = 0.0
            var bestSpeaker: Int? = nil
            for t in turns {
                let overlap = min(seg.end, t.end) - max(seg.start, t.start)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = t.speaker
                }
            }
            if let bestSpeaker {
                out.speaker = bestSpeaker
            } else {
                // No overlap at all (e.g. a segment inside a diarizer silence gap) → nearest midpoint.
                let mid = (seg.start + seg.end) / 2
                var bestDist = Double.infinity
                var nearest = turns[0].speaker
                for t in turns {
                    let dist = abs((t.start + t.end) / 2 - mid)
                    if dist < bestDist { bestDist = dist; nearest = t.speaker }
                }
                out.speaker = nearest
            }
            return out
        }
    }
}
