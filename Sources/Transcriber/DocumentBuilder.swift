import Foundation

// MARK: - Document model (shared by capture, OCR, builder, exporter)

/// A spoken-transcript segment, timestamped relative to the session clock T0 (seconds).
/// `speaker` (1-based slot from diarization), `cleanedText` (Stage-1 cleanup pass), and
/// `redactedText` (Stage-2 PII/PHI redaction pass) are all optional and absent-by-default, so old
/// `session.json` files decode unchanged and a session recorded with those features off encodes
/// byte-identically to before (synthesized `encode(to:)` uses `encodeIfPresent` for optionals).
struct TranscriptSegment: Sendable, Codable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var speaker: Int? = nil
    var cleanedText: String? = nil
    /// Stage 2 (Feature C2): the redacted form of `text` with PII/PHI masked. The verbatim `text`
    /// and the `[mm:ss]` anchors are never touched; this is a parallel view, opt-in in the Viewer.
    var redactedText: String? = nil
}

/// A captured screenshot, timestamped relative to the same session clock T0 (seconds).
/// `imagePath` is RELATIVE to the session folder (e.g. "images/0003-14.png") so the folder
/// stays self-contained and movable.
struct FrameEvent: Sendable, Codable {
    var sessionTime: TimeInterval
    var imagePath: String
    var ocrText: String?
}

/// A user-dropped marker captured live (⌥⌘B) or added in the Viewer, in seconds from session T0.
struct Bookmark: Sendable, Codable, Identifiable, Hashable {
    var time: TimeInterval
    var label: String?
    var id: String { String(format: "bm-%.3f", time) }
}

/// A topic segment of the session with a start time (seconds from T0), shown as a clickable jump point.
struct Chapter: Sendable, Codable, Identifiable, Hashable {
    var start: TimeInterval
    var title: String
    var id: String { String(format: "ch-%.3f", start) }
}

/// A cached, on-device-generated artifact (Feature A — Generation Studio). Stored in
/// `SessionMeta.generatedArtifacts` keyed by template id, so reopening a session shows prior output
/// without re-running the model. `content` is the rendered text for text templates, or a JSON
/// encoding of the `@Generable` value for structured ones (so the Viewer can render it richly).
struct GeneratedArtifact: Sendable, Codable, Hashable {
    var templateId: String
    var format: String          // "text" or "json"
    var content: String
    var createdAt: Date
}

struct SessionMeta: Sendable, Codable {
    var date: Date
    var sourceLabel: String
    var modelName: String
    var targetLabel: String?
    var modeLabel: String?
    // Unified session store (Prompt 1): auto-generated title + tags, plus a schema marker.
    // All optional/defaulted and decoded with `decodeIfPresent`, so a `session.json` written before
    // these fields existed (older visual / Prompt-1 sessions) still decodes cleanly.
    var title: String?
    var tags: [String]
    var schemaVersion: Int
    // Prompt 2 (Chat & Intelligence / Capture / UX): generated artifacts + saved-audio reference,
    // all backward-compatible (decodeIfPresent → sensible empty defaults).
    var audioFile: String?                 // relative filename of saved playback audio (e.g. "audio.m4a")
    var durationSeconds: Double?           // recording/import length, for the player + SRT bounds
    var bookmarks: [Bookmark]
    var chapters: [Chapter]
    var actionItems: [String]
    var summaries: [String: String]        // SummaryStyle.rawValue (or "custom:<name>") → cached summary
    var imported: Bool                      // true for drag-drop / Import sessions
    // Stage 1 (diarization / multilingual): all optional + decodeIfPresent → old session.json decodes
    // unchanged, and sessions recorded with the features off omit the keys entirely.
    var speakerCount: Int?                  // distinct diarized speakers (nil = never diarized)
    var speakerNames: [String: String]?     // speaker slot ("1") → user-chosen name ("Alice")
    var language: String?                   // resolved transcription language when not the default "en"
    // Stage 2: all optional + decodeIfPresent → old session.json decodes unchanged, and sessions
    // produced with these features untouched omit the keys entirely (byte-identical default encoding).
    var generatedArtifacts: [String: GeneratedArtifact]?  // Feature A: template id → cached output
    var retentionLocked: Bool?              // Feature C1: true exempts the session from auto-delete

    static let currentSchemaVersion = 2

    init(date: Date, sourceLabel: String, modelName: String,
         targetLabel: String? = nil, modeLabel: String? = nil,
         title: String? = nil, tags: [String] = [], schemaVersion: Int = SessionMeta.currentSchemaVersion,
         audioFile: String? = nil, durationSeconds: Double? = nil,
         bookmarks: [Bookmark] = [], chapters: [Chapter] = [], actionItems: [String] = [],
         summaries: [String: String] = [:], imported: Bool = false,
         speakerCount: Int? = nil, speakerNames: [String: String]? = nil, language: String? = nil,
         generatedArtifacts: [String: GeneratedArtifact]? = nil, retentionLocked: Bool? = nil) {
        self.date = date
        self.sourceLabel = sourceLabel
        self.modelName = modelName
        self.targetLabel = targetLabel
        self.modeLabel = modeLabel
        self.title = title
        self.tags = tags
        self.schemaVersion = schemaVersion
        self.audioFile = audioFile
        self.durationSeconds = durationSeconds
        self.bookmarks = bookmarks
        self.chapters = chapters
        self.actionItems = actionItems
        self.summaries = summaries
        self.imported = imported
        self.speakerCount = speakerCount
        self.speakerNames = speakerNames
        self.language = language
        self.generatedArtifacts = generatedArtifacts
        self.retentionLocked = retentionLocked
    }

    enum CodingKeys: String, CodingKey {
        case date, sourceLabel, modelName, targetLabel, modeLabel, title, tags, schemaVersion
        case audioFile, durationSeconds, bookmarks, chapters, actionItems, summaries, imported
        case speakerCount, speakerNames, language
        case generatedArtifacts, retentionLocked
    }

    // Custom decode for backward compatibility: older session.json files lack the newer fields.
    // (Swift's synthesized Decodable does NOT fall back to property defaults for missing keys, so we
    // must decodeIfPresent the new fields explicitly.) `encode(to:)` stays synthesized via CodingKeys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        sourceLabel = try c.decode(String.self, forKey: .sourceLabel)
        modelName = try c.decode(String.self, forKey: .modelName)
        targetLabel = try c.decodeIfPresent(String.self, forKey: .targetLabel)
        modeLabel = try c.decodeIfPresent(String.self, forKey: .modeLabel)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        audioFile = try c.decodeIfPresent(String.self, forKey: .audioFile)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        summaries = try c.decodeIfPresent([String: String].self, forKey: .summaries) ?? [:]
        imported = try c.decodeIfPresent(Bool.self, forKey: .imported) ?? false
        speakerCount = try c.decodeIfPresent(Int.self, forKey: .speakerCount)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        generatedArtifacts = try c.decodeIfPresent([String: GeneratedArtifact].self, forKey: .generatedArtifacts)
        retentionLocked = try c.decodeIfPresent(Bool.self, forKey: .retentionLocked)
    }

    /// Display name for a diarized speaker slot: the user's rename when present, else "Speaker N".
    func speakerLabel(_ slot: Int) -> String {
        if let name = speakerNames?[String(slot)]?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        return "Speaker \(slot)"
    }
}

/// The full session document — written as `session.json` so the folder is self-describing
/// (the exporter rebuilds HTML/PDF from this without re-parsing Markdown).
struct SessionDoc: Sendable, Codable {
    var meta: SessionMeta
    var segments: [TranscriptSegment]
    var frames: [FrameEvent]
}

// MARK: - DocumentBuilder

/// Merges transcript segments + frame events into one time-sorted timeline and renders it.
/// Both inputs are relative to a single session clock `T0` (captured at recording start with
/// `CACurrentMediaTime()`): WhisperKit segment timestamps are relative to the audio buffer start,
/// which also begins at T0; frame events are stamped `CACurrentMediaTime() - T0`. Same clock →
/// alignment is free.
enum DocumentBuilder {

    static func timestamp(_ t: TimeInterval) -> String {
        let total = Int(max(0, t).rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Session folder layout

    /// A per-session folder `~/Desktop/Transcripts/<yyyy-MM-dd HH-mm-ss>/`. Visual sessions also get
    /// an `images/` subdir; audio-only sessions (unified store) get just the folder (no empty images/).
    static func makeSessionFolder(date: Date, withImages: Bool = true) -> URL {
        let dir = AppModel.transcriptsDirectory
            .appendingPathComponent(folderStamp.string(from: date), isDirectory: true)
        let target = withImages ? dir.appendingPathComponent("images", isDirectory: true) : dir
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return dir
    }

    /// Write `transcript.md` + machine-readable `session.json` into the session folder.
    static func writeSession(_ doc: SessionDoc, to sessionDir: URL) {
        let md = markdown(meta: doc.meta, segments: doc.segments, frames: doc.frames)
        // Route through SessionIO so encryption-at-rest (Feature C4) is transparent. When encryption
        // is OFF (default) this is a byte-identical plain UTF-8 write — same bytes as before.
        try? SessionIO.writeText(md, to: sessionDir.appendingPathComponent("transcript.md"))
        writeSessionJSON(doc, to: sessionDir)
    }

    /// Write ONLY `session.json`, leaving `transcript.md` untouched. Used by (a) migration, which must
    /// preserve the original transcript bytes copied in as transcript.md, and (b) title/tag backfill,
    /// which only updates `meta` and must not re-render (and possibly reformat) the transcript.
    static func writeSessionJSON(_ doc: SessionDoc, to sessionDir: URL) {
        if let json = try? JSONEncoder().encode(doc) {
            // Atomic (so a concurrent reader never sees a torn file) + routed through SessionIO for
            // transparent encryption-at-rest. OFF (default) ⇒ byte-identical plain write.
            try? SessionIO.writeData(json, to: sessionDir.appendingPathComponent("session.json"))
        }
    }

    static func readSession(_ sessionDir: URL) -> SessionDoc? {
        guard let data = try? SessionIO.readData(sessionDir.appendingPathComponent("session.json")) else { return nil }
        return try? JSONDecoder().decode(SessionDoc.self, from: data)
    }

    // MARK: Markdown

    static func markdown(meta: SessionMeta, segments: [TranscriptSegment], frames: [FrameEvent]) -> String {
        var out = "# Transcript — \(humanStamp.string(from: meta.date))\n\n"
        out += "- **Source:** \(meta.sourceLabel)\n"
        out += "- **Model:** \(meta.modelName)\n"
        if let t = meta.targetLabel { out += "- **Visual target:** \(t)\n" }
        if let m = meta.modeLabel { out += "- **Capture mode:** \(m)\n" }
        out += "\n---\n\n"

        let items = timeline(segments: segments, frames: frames)
        if items.isEmpty {
            out += "_(no speech detected)_\n"
            return out
        }

        for item in items {
            switch item {
            case .text(let seg):
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Diarized sessions prefix a resolved speaker label AFTER the [mm:ss] anchor, so
                // click-to-seek, SearchIndex parsing, and stripLeadingTimestamp all keep working.
                // No speaker (feature off / pre-Stage-1 session) → byte-identical to before.
                let label = seg.speaker.map { "**\(meta.speakerLabel($0)):** " } ?? ""
                if !text.isEmpty { out += "[\(timestamp(seg.start))] \(label)\(text)\n\n" }
            case .frame(let f):
                let ts = timestamp(f.sessionTime)
                out += "![\(ts)](\(f.imagePath))\n\n"
                if let ocr = f.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
                    out += "<details><summary>On-slide text (\(ts))</summary>\n\n```\n\(ocr)\n```\n\n</details>\n\n"
                }
            }
        }
        return out
    }

    // MARK: HTML (self-contained, images embedded as base64 data URIs)

    /// `imageData` resolves a frame's relative `imagePath` to PNG bytes for base64 embedding.
    static func html(meta: SessionMeta,
                     segments: [TranscriptSegment],
                     frames: [FrameEvent],
                     imageData: (String) -> Data?) -> String {
        var body = ""
        for item in timeline(segments: segments, frames: frames) {
            switch item {
            case .text(let seg):
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let label = seg.speaker.map { "<b>\(escape(meta.speakerLabel($0))):</b> " } ?? ""
                    body += "<p><span class=\"ts\">\(timestamp(seg.start))</span> \(label)\(escape(text))</p>\n"
                }
            case .frame(let f):
                let ts = timestamp(f.sessionTime)
                if let data = imageData(f.imagePath) {
                    let uri = "data:image/png;base64,\(data.base64EncodedString())"
                    body += "<figure><img src=\"\(uri)\" alt=\"\(ts)\"/><figcaption>\(ts)</figcaption></figure>\n"
                } else {
                    body += "<p class=\"ts\">[image \(ts) missing]</p>\n"
                }
                if let ocr = f.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
                    body += "<details><summary>On-slide text (\(ts))</summary><pre>\(escape(ocr))</pre></details>\n"
                }
            }
        }

        var meta1 = "<li><b>Source:</b> \(escape(meta.sourceLabel))</li><li><b>Model:</b> \(escape(meta.modelName))</li>"
        if let t = meta.targetLabel { meta1 += "<li><b>Visual target:</b> \(escape(t))</li>" }
        if let m = meta.modeLabel { meta1 += "<li><b>Capture mode:</b> \(escape(m))</li>" }

        return """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Transcript — \(escape(humanStamp.string(from: meta.date)))</title>
        <style>
          body { font: 15px/1.55 -apple-system, system-ui, sans-serif; max-width: 820px; margin: 40px auto; padding: 0 20px; color: #1c1c1e; }
          h1 { font-size: 22px; }
          ul.meta { color: #555; list-style: none; padding: 0; font-size: 13px; }
          ul.meta li { display: inline-block; margin-right: 16px; }
          hr { border: none; border-top: 1px solid #e0e0e0; margin: 20px 0; }
          .ts { color: #8a8a8e; font-variant-numeric: tabular-nums; font-size: 12px; margin-right: 6px; }
          figure { margin: 20px 0; }
          img { max-width: 100%; border: 1px solid #e0e0e0; border-radius: 8px; display: block; }
          figcaption { color: #8a8a8e; font-size: 12px; margin-top: 4px; }
          details { background: #f6f6f7; border-radius: 8px; padding: 8px 12px; margin: 8px 0 16px; }
          summary { cursor: pointer; color: #555; font-size: 13px; }
          pre { white-space: pre-wrap; font: 12px/1.45 ui-monospace, Menlo, monospace; margin: 8px 0 0; }
        </style></head><body>
        <h1>Transcript — \(escape(humanStamp.string(from: meta.date)))</h1>
        <ul class="meta">\(meta1)</ul><hr>
        \(body)
        </body></html>
        """
    }

    // MARK: - Internal

    private enum Item { case text(TranscriptSegment); case frame(FrameEvent) }

    private static func timeline(segments: [TranscriptSegment], frames: [FrameEvent]) -> [Item] {
        var items: [(time: TimeInterval, order: Int, item: Item)] = []
        for s in segments { items.append((s.start, 0, .text(s))) }
        for f in frames { items.append((f.sessionTime, 1, .frame(f))) }
        // Stable sort by time; on ties, text before image (order field).
        items.sort { $0.time != $1.time ? $0.time < $1.time : $0.order < $1.order }
        return items.map { $0.item }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static let folderStamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"; return f
    }()
    private static let humanStamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
}
