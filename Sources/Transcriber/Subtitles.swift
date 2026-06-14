import Foundation

/// Subtitle generation (SRT + WebVTT) from a session's timed segments — near-free, fully offline.
/// Cues are sanitized to be monotonic and non-overlapping. When a session has no usable timing,
/// the `…(dir:)` builders return nil so callers can show a clear "no timing available" note.
enum Subtitles {

    /// Sanitize raw segments into monotonic, non-overlapping cues with a minimum on-screen duration.
    static func cues(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let sorted = segments
            .map { TranscriptSegment(start: max(0, $0.start), end: max(0, $0.end),
                                     text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
        var out: [TranscriptSegment] = []
        for (i, seg) in sorted.enumerated() {
            var start = seg.start
            if let prev = out.last, start < prev.end { start = prev.end }   // no overlap with previous
            var end = max(seg.end, start + 0.3)                              // minimum 0.3 s on screen
            if i + 1 < sorted.count { end = min(end, max(start + 0.3, sorted[i + 1].start)) }
            out.append(TranscriptSegment(start: start, end: end, text: seg.text))
        }
        return out
    }

    static func srt(segments: [TranscriptSegment]) -> String {
        let cues = cues(from: segments)
        var out = ""
        for (i, c) in cues.enumerated() {
            out += "\(i + 1)\n\(stamp(c.start, sep: ",")) --> \(stamp(c.end, sep: ","))\n\(c.text)\n\n"
        }
        return out
    }

    static func vtt(segments: [TranscriptSegment]) -> String {
        let cues = cues(from: segments)
        var out = "WEBVTT\n\n"
        for (i, c) in cues.enumerated() {
            out += "\(i + 1)\n\(stamp(c.start, sep: ".")) --> \(stamp(c.end, sep: "."))\n\(c.text)\n\n"
        }
        return out
    }

    /// Build SRT for a session folder (nil → no usable timing).
    static func srt(dir: URL) -> String? {
        let segs = SessionStore.timedSegments(dir: dir)
        guard !segs.isEmpty else { return nil }
        return srt(segments: segs)
    }

    static func vtt(dir: URL) -> String? {
        let segs = SessionStore.timedSegments(dir: dir)
        guard !segs.isEmpty else { return nil }
        return vtt(segments: segs)
    }

    /// HH:MM:SS,mmm (SRT) or HH:MM:SS.mmm (VTT) depending on `sep`.
    private static func stamp(_ t: TimeInterval, sep: String) -> String {
        let total = max(0, t)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int((total - total.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, sep, ms)
    }
}
