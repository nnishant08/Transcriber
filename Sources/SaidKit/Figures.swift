import Foundation
import CryptoKit

// MARK: - The figure
//
// A figure is a QUANTITY plus what it is a quantity of, anchored to the moment it was said.
//
// Everything about it is derived: it lives in `figures.json` beside the transcript, never inside
// `transcript.md` (which stays the verbatim record — prime directive #1), and it can be thrown away
// and recomputed at any time. That is what lets the detector be re-run freely, the labeller be
// optional, and the whole feature be OFF by default with no trace on disk.

/// The classes a figure can belong to (§3). Order is the overlap PRIORITY: when two candidates
/// cover the same words at the same length, the earlier class wins.
public enum FigureClass: String, Codable, CaseIterable, Sendable {
    case money, percentage, multiplier, count, duration

    public var label: String {
        switch self {
        case .money:      return "Money"
        case .percentage: return "Percentages"
        case .multiplier: return "Multipliers"
        case .count:      return "Counts"
        case .duration:   return "Durations & deadlines"
        }
    }

    /// Lower wins on an exact-length tie.
    var priority: Int { FigureClass.allCases.firstIndex(of: self) ?? .max }
}

/// One detected figure, with its three anchors (§P3).
///
/// - **word-index range** (`wordStart..<wordEnd`) into the segment's `validWords`. The anchor that
///   RENDERING uses, because word indices survive an edit elsewhere in the turn. `nil` when the
///   segment carries no word timings (every legacy session).
/// - **character range** (`charStart..<charEnd`) into the segment's TEXT — `Character` offsets, so
///   both platforms count identically. Stored for export and the search index, and as the ONLY
///   anchor for a session with no word timings. Never used for rendering when words exist.
/// - **time range** (`start`…`end`) on the session clock, from the words when there are words and
///   from the segment bounds when there are not. This is what "click to seek" seeks to.
///
/// `raw` is the figure exactly as written. It is the fingerprint every anchor is checked against:
/// a figure is rendered only while the text at its anchor still reads `raw`. **A stale anchor is
/// never rendered** (prime directive #6).
///
/// **The character range is relative to the segment, not to `transcript.md`.** The build prompt
/// asked for an offset into the file. A file offset dies on the first speaker rename (the file is
/// re-rendered with `**Name:**` labels), on the title landing (the file is renamed) and on every
/// re-render — none of which touch the words. Segment-relative offsets survive all three.
public struct Figure: Codable, Sendable, Equatable, Identifiable {
    public let segmentIndex: Int
    public let wordStart: Int?
    public let wordEnd: Int?
    public let charStart: Int
    public let charEnd: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let raw: String
    public let kind: FigureClass
    /// The parsed magnitude, when it parses. `nil` for a deadline ("by year end") and for a
    /// multiplier word with no numeral ("doubled"). Display uses `raw`, never this.
    public let value: Double?
    /// Normalised unit: an ISO currency code, `%`, `bps`, `x`, or the singular unit word.
    public let unit: String?
    /// What the number is a number OF — from the labeller, `nil` when it could not say (§P2).
    public var label: String?
    public var confidence: Double?
    /// The speaker slot of the turn it was said in. A figure belongs to exactly one speaker.
    public let speaker: Int?

    public init(segmentIndex: Int, wordStart: Int?, wordEnd: Int?, charStart: Int, charEnd: Int,
                start: TimeInterval, end: TimeInterval, raw: String, kind: FigureClass,
                value: Double?, unit: String?, label: String? = nil, confidence: Double? = nil,
                speaker: Int?) {
        self.segmentIndex = segmentIndex
        self.wordStart = wordStart
        self.wordEnd = wordEnd
        self.charStart = charStart
        self.charEnd = charEnd
        self.start = start
        self.end = end
        self.raw = raw
        self.kind = kind
        self.value = value
        self.unit = unit
        self.label = label
        self.confidence = confidence
        self.speaker = speaker
    }

    public var id: String { "fig-\(segmentIndex)-\(charStart)" }
    public var hasWordAnchor: Bool { wordStart != nil && wordEnd != nil }
    public var timestamp: String { DocumentBuilder.timestamp(start) }
    /// The identity of the candidate independent of its label — what lets a re-extraction reuse
    /// the label the model already gave this exact figure.
    public var candidateKey: String { "\(segmentIndex)|\(kind.rawValue)|\(raw)" }
}

/// The detector's output type. The same shape as `Figure` with `label`/`confidence` nil — one
/// type rather than two, so a candidate that never reaches the labeller (no Apple Intelligence,
/// call cap hit) IS the stored figure, with nothing to convert.
public typealias FigureCandidate = Figure

// MARK: - Rendering against the overlay (§P3)

/// A figure that has been checked against the text it will be drawn on, with the range to draw.
public struct ResolvedFigure: Sendable, Equatable, Identifiable {
    public let figure: Figure
    /// `Character` offsets into the DISPLAYED segment text (edited view or verbatim — whichever
    /// the caller handed in).
    public let displayRange: Range<Int>
    public var id: String { figure.id }
}

/// Every row of the §P3 anchoring table, as one pure function.
public enum FigureOverlay {

    /// Resolve `figures` against `segments` — the segments AS DISPLAYED (edited view when the
    /// Viewer shows it, verbatim otherwise).
    ///
    /// | Situation | Behaviour |
    /// |---|---|
    /// | overlay leaves the figure's words untouched | render |
    /// | overlay edits elsewhere in the turn | render; display range re-derived from the WORD anchor |
    /// | overlay edits a word inside the figure | DROP (never partially render, never re-detect inline) |
    /// | overlay rewrote the whole turn (words become nil) | DROP |
    /// | the turn is gone (segment index out of range) | DROP |
    ///
    /// Re-transcription is handled one level up: `FigureStore.read` invalidates the whole sidecar
    /// when the transcript fingerprint no longer matches, so nothing here ever sees figures from a
    /// different engine's word table.
    public static func resolve(_ figures: [Figure], in segments: [TranscriptSegment]) -> (resolved: [ResolvedFigure], dropped: Int) {
        var out: [ResolvedFigure] = []
        var dropped = 0
        for f in figures {
            if let r = resolveOne(f, in: segments) { out.append(r) } else { dropped += 1 }
        }
        return (out, dropped)
    }

    static func resolveOne(_ f: Figure, in segments: [TranscriptSegment]) -> ResolvedFigure? {
        guard segments.indices.contains(f.segmentIndex) else { return nil }
        let seg = segments[f.segmentIndex]
        let chars = Array(seg.text)

        if let ws = f.wordStart, let we = f.wordEnd {
            // A word anchor NEVER falls back to character offsets (§P3): if the words are gone, the
            // figure is gone. That is the "silence beats a confident lie" rule made structural.
            guard let words = seg.validWords, ws >= 0, we <= words.count, ws < we else { return nil }
            guard let ranges = WordAlignment.characterRanges(words: words, text: seg.text),
                  ranges.indices.contains(ws), ranges.indices.contains(we - 1) else { return nil }
            let lo = ranges[ws].lowerBound, hi = ranges[we - 1].upperBound
            guard lo < hi, hi <= chars.count else { return nil }
            // The text under the anchor must still read `raw`. An edit INSIDE the range changes
            // it → drop. An edit elsewhere leaves it → render at the re-derived range. The words'
            // span can carry the punctuation the detector peeled off ("dollars," vs "dollars"), so
            // `raw` is located WITHIN the span rather than compared against all of it.
            let span = chars[lo..<hi]
            let rawChars = Array(f.raw)
            guard let offset = firstOccurrence(of: rawChars, in: span) else { return nil }
            return ResolvedFigure(figure: f, displayRange: (lo + offset)..<(lo + offset + rawChars.count))
        }

        // No word anchor (a legacy session): the character range is the only anchor there is, and
        // it is trusted only while the text at that position is unchanged.
        guard f.charStart >= 0, f.charEnd <= chars.count, f.charStart < f.charEnd,
              String(chars[f.charStart..<f.charEnd]) == f.raw else { return nil }
        return ResolvedFigure(figure: f, displayRange: f.charStart..<f.charEnd)
    }

    private static func firstOccurrence(of needle: [Character], in hay: ArraySlice<Character>) -> Int? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        let base = hay.startIndex
        for i in 0...(hay.count - needle.count) {
            var ok = true
            for k in 0..<needle.count where hay[base + i + k] != needle[k] { ok = false; break }
            if ok { return i }
        }
        return nil
    }
}

// MARK: - Word ↔ character alignment

/// Where each of a segment's words sits in its text.
///
/// Engines write words that concatenate (with the segment's own punctuation and spacing) into the
/// text, so a forward search from a moving cursor finds each one — the same discipline
/// `EditOverlay.replacing(occurrence:)` uses to substitute the right occurrence rather than
/// rebuilding the line. A word that cannot be found ends the alignment: the remaining words get no
/// range, and a figure over them gets no word anchor, which is the honest outcome.
public enum WordAlignment {

    /// `Character` ranges into `text`, one per word, or `nil` when NO word could be placed.
    /// The array is as long as the prefix that aligned; callers index it defensively.
    public static func characterRanges(words: [WordTiming], text: String) -> [Range<Int>]? {
        let chars = Array(text)
        var out: [Range<Int>] = []
        var cursor = 0
        for w in words {
            let needle = Array(w.text.trimmingCharacters(in: .whitespaces))
            guard !needle.isEmpty else { break }
            guard let r = find(needle, in: chars, from: cursor)
                    ?? find(Array(strip(w.text)), in: chars, from: cursor) else { break }
            out.append(r)
            cursor = r.upperBound
        }
        return out.isEmpty ? nil : out
    }

    /// Word indices (half-open) whose character ranges intersect `range`, or nil if none do or
    /// the alignment did not reach them.
    public static func wordRange(covering range: Range<Int>, ranges: [Range<Int>]) -> Range<Int>? {
        var first: Int? = nil, last: Int? = nil
        for (i, r) in ranges.enumerated() where r.overlaps(range) {
            if first == nil { first = i }
            last = i
        }
        guard let f = first, let l = last else { return nil }
        return f..<(l + 1)
    }

    private static func find(_ needle: [Character], in hay: [Character], from start: Int) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= hay.count - start else { return nil }
        var i = max(0, start)
        let limit = hay.count - needle.count
        while i <= limit {
            if hay[i] == needle[0] {
                var ok = true
                for k in 1..<needle.count where hay[i + k] != needle[k] { ok = false; break }
                if ok { return i..<(i + needle.count) }
            }
            i += 1
        }
        return nil
    }

    static func strip(_ s: String) -> String {
        var t = Substring(s.trimmingCharacters(in: .whitespaces))
        while let f = t.first, !(f.isLetter || f.isNumber || f == "$" || f == "€" || f == "£") { t.removeFirst() }
        while let l = t.last, !(l.isLetter || l.isNumber || l == "%") { t.removeLast() }
        return String(t)
    }
}

// MARK: - The sidecar (§P4)

/// `figures.json`. Derived, optional, versioned.
public struct FigureSidecar: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    /// Hash of the verbatim segments + engine. A re-transcription changes it, which invalidates
    /// the whole file: word indices from a different engine are not the same word indices.
    public var transcriptFingerprint: String
    public var engine: String?
    public var engineModel: String?
    public var extractedAt: Date
    /// Whether the labeller ran to completion on this extraction. False when Apple Intelligence
    /// was unavailable, the call cap was hit, or labelling was skipped for heat — all supported
    /// states, none an error.
    public var labelled: Bool
    /// Model calls spent on this extraction (for the cap, and for the report).
    public var labelCalls: Int
    public var figures: [Figure]

    public static let currentSchemaVersion = 1

    public init(transcriptFingerprint: String, engine: String?, engineModel: String?,
                extractedAt: Date, labelled: Bool, labelCalls: Int, figures: [Figure],
                schemaVersion: Int = FigureSidecar.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.transcriptFingerprint = transcriptFingerprint
        self.engine = engine
        self.engineModel = engineModel
        self.extractedAt = extractedAt
        self.labelled = labelled
        self.labelCalls = labelCalls
        self.figures = figures
    }
}

/// Why a sidecar was not usable. Every case means "re-extract", never "fail".
public enum FigureSidecarState: Sendable, Equatable {
    /// No file, or the feature has never run on this session.
    case absent
    /// A file is there but cannot be trusted: unknown schema, a corrupt file, or a transcript that
    /// has been re-transcribed since. The reason is for the log; the behaviour is the same.
    case stale(String)
    case ready(FigureSidecar)

    public var sidecar: FigureSidecar? { if case .ready(let s) = self { return s }; return nil }
}

public enum FigureStore {

    public static let fileName = "figures.json"

    /// Default OFF (prime directive #5). With it off, nothing in this wave reads or writes a byte.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "figuresEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "figuresEnabled") }
    }

    public static func url(dir: URL) -> URL { dir.appendingPathComponent(fileName) }

    /// The transcript identity a sidecar is bound to: the verbatim segments' bounds and text plus
    /// the engine record. Edits are NOT part of it — an edit drops the one figure under it and
    /// flags the session, it does not invalidate the file (§P3's table draws that line).
    public static func fingerprint(segments: [TranscriptSegment], meta: SessionMeta) -> String {
        var h = SHA256()
        h.update(data: Data((meta.engine ?? "").utf8)); h.update(data: Data([0]))
        h.update(data: Data((meta.engineModel ?? "").utf8)); h.update(data: Data([0]))
        for s in segments {
            h.update(data: Data(String(format: "%.3f|%.3f|", s.start, s.end).utf8))
            h.update(data: Data(s.text.utf8)); h.update(data: Data([0]))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Read the sidecar for `dir`, validated against the session it sits beside.
    ///
    /// **Never throws and never makes a session unopenable.** A future schema, a damaged file, or a
    /// fingerprint that no longer matches all come back as `.stale`, and the caller re-extracts.
    public static func read(dir: URL, doc: SessionDoc? = nil) -> FigureSidecarState {
        let u = url(dir: dir)
        guard FileManager.default.fileExists(atPath: u.path),
              let data = try? SessionIO.readData(u) else { return .absent }
        // Peek at the version before decoding the rest, so an unknown version is "ignore", not
        // "throw on an unfamiliar field".
        guard let head = try? JSONDecoder().decode(VersionOnly.self, from: data) else {
            NSLog("[Figures] \(fileName) could not be decoded; ignoring it")
            return .stale("undecodable")
        }
        guard head.schemaVersion == FigureSidecar.currentSchemaVersion else {
            NSLog("[Figures] \(fileName) is schema \(head.schemaVersion); this build reads \(FigureSidecar.currentSchemaVersion). Ignoring it.")
            return .stale("schema \(head.schemaVersion)")
        }
        guard let sidecar = try? decoder.decode(FigureSidecar.self, from: data) else {
            NSLog("[Figures] \(fileName) has the right version but an unexpected shape; ignoring it")
            return .stale("undecodable")
        }
        let doc = doc ?? DocumentBuilder.readSession(dir)
        if let doc, fingerprint(segments: doc.segments, meta: doc.meta) != sidecar.transcriptFingerprint {
            return .stale("transcript changed")
        }
        return .ready(sidecar)
    }

    private struct VersionOnly: Decodable { let schemaVersion: Int }

    public static func write(_ sidecar: FigureSidecar, dir: URL) throws {
        try SessionIO.writeData(try encoder.encode(sidecar), to: url(dir: dir))
    }

    public static func remove(dir: URL) {
        let u = url(dir: dir)
        if FileManager.default.fileExists(atPath: u.path) { try? FileManager.default.removeItem(at: u) }
    }

    /// The figures for a session that are safe to display, or `[]`. One call for every surface
    /// (rail, inline, search, Ask) — so no surface can disagree with another about what exists.
    /// With the feature OFF this returns `[]` without touching disk.
    public static func figures(dir: URL, doc: SessionDoc? = nil) -> [Figure] {
        guard isEnabled else { return [] }
        return read(dir: dir, doc: doc).sidecar?.figures ?? []
    }

    // Sorted keys + ISO dates so the file is diffable and byte-identical across platforms for the
    // same content — which is what the cross-platform round-trip fixture asserts.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Density (§Q1, §9)

/// When a turn is so dense with figures that washing each one would turn it into a highlighted
/// mess, the wash is dropped and the rail carries the figures alone.
public enum FigureDensity {
    /// Figures per hundred words above which a Mac turn loses its inline wash. Twelve is one
    /// figure every eight words — the "financial review" density the prompt names — so anything
    /// denser than a review reads as text.
    public static let macCeilingPerHundredWords = 12
    /// Lower on the phone: the column is a third the width, so one wash covers far more of a
    /// line, and with no hover the wash is the whole inline affordance — it has to stay rare to
    /// stay legible.
    public static let phoneCeilingPerHundredWords = 8

    /// A single figure is always washed: density only means anything with two or more.
    public static func washAllowed(figureCount: Int, wordCount: Int, ceilingPerHundredWords ceiling: Int) -> Bool {
        guard figureCount > 1 else { return true }
        let words = max(1, wordCount)
        return figureCount * 100 <= words * ceiling
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

// MARK: - Runs for rendering

/// A displayed line split into plain words and figure spans, so both platforms can lay it out as
/// wrapping runs with each figure a real, focusable control. Pure.
public enum FigureRun: Sendable, Equatable {
    case word(String)
    case figure(ResolvedFigure, String)
}

public enum FigureRuns {
    public static func split(text: String, figures: [ResolvedFigure]) -> [FigureRun] {
        let chars = Array(text)
        let sorted = figures.filter { $0.displayRange.upperBound <= chars.count }
            .sorted { $0.displayRange.lowerBound < $1.displayRange.lowerBound }
        var out: [FigureRun] = []
        var cursor = 0
        func emitWords(_ lo: Int, _ hi: Int) {
            guard lo < hi else { return }
            for w in String(chars[lo..<hi]).split(whereSeparator: { $0.isWhitespace }) { out.append(.word(String(w))) }
        }
        for f in sorted where f.displayRange.lowerBound >= cursor {
            emitWords(cursor, f.displayRange.lowerBound)
            out.append(.figure(f, String(chars[f.displayRange])))
            cursor = f.displayRange.upperBound
        }
        emitWords(cursor, chars.count)
        return out
    }
}
