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
    // Screen recording: the session's video, on the same pause-compressed clock as the transcript.
    // Relative filename so the folder stays self-contained and movable — "screen.mp4" for a recorded
    // session, the copied original for an imported video. Absent (nil) for audio-only sessions, so
    // their session.json is unchanged.
    var videoFile: String?
    var videoWidth: Int?
    var videoHeight: Int?

    static let currentSchemaVersion = 2

    init(date: Date, sourceLabel: String, modelName: String,
         targetLabel: String? = nil, modeLabel: String? = nil,
         title: String? = nil, tags: [String] = [], schemaVersion: Int = SessionMeta.currentSchemaVersion,
         audioFile: String? = nil, durationSeconds: Double? = nil,
         bookmarks: [Bookmark] = [], chapters: [Chapter] = [], actionItems: [String] = [],
         summaries: [String: String] = [:], imported: Bool = false,
         speakerCount: Int? = nil, speakerNames: [String: String]? = nil, language: String? = nil,
         generatedArtifacts: [String: GeneratedArtifact]? = nil, retentionLocked: Bool? = nil,
         videoFile: String? = nil, videoWidth: Int? = nil, videoHeight: Int? = nil) {
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
        self.videoFile = videoFile
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
    }

    enum CodingKeys: String, CodingKey {
        case date, sourceLabel, modelName, targetLabel, modeLabel, title, tags, schemaVersion
        case audioFile, durationSeconds, bookmarks, chapters, actionItems, summaries, imported
        case speakerCount, speakerNames, language
        case generatedArtifacts, retentionLocked
        case videoFile, videoWidth, videoHeight
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
        videoFile = try c.decodeIfPresent(String.self, forKey: .videoFile)
        videoWidth = try c.decodeIfPresent(Int.self, forKey: .videoWidth)
        videoHeight = try c.decodeIfPresent(Int.self, forKey: .videoHeight)
    }

    /// True when this session has a video to play alongside the transcript.
    var hasVideo: Bool { videoFile?.isEmpty == false }

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

    init(meta: SessionMeta, segments: [TranscriptSegment]) {
        self.meta = meta
        self.segments = segments
    }

    // Decoded explicitly so a pre-screen-recording `session.json` — which carries a `frames` array
    // from the removed screenshot feature — still decodes cleanly. The extra key is simply ignored.
    enum CodingKeys: String, CodingKey { case meta, segments }
}

// MARK: - DocumentBuilder

/// Renders a session's timestamped transcript to Markdown / HTML.
///
/// Everything in a session is measured on ONE clock: `T0`, captured at recording start with
/// `CACurrentMediaTime()` and compressed by any paused time. WhisperKit's segment timestamps are
/// relative to the audio buffer, which starts at T0, and the screen recording's frames are stamped
/// on the same compressed clock — so `[mm:ss]`, the audio, and the video all line up for free.
enum DocumentBuilder {

    static func timestamp(_ t: TimeInterval) -> String {
        let total = Int(max(0, t).rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Session folder layout

    /// A per-session folder `~/Desktop/Transcripts/<yyyy-MM-dd HH-mm-ss>/`. Self-contained and
    /// movable: `transcript.md` + `session.json`, plus `audio.m4a` / `screen.mp4` when those exist.
    static func makeSessionFolder(date: Date) -> URL {
        let dir = AppModel.transcriptsDirectory
            .appendingPathComponent(folderStamp.string(from: date), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write `transcript.md` + machine-readable `session.json` into the session folder.
    static func writeSession(_ doc: SessionDoc, to sessionDir: URL) {
        let md = markdown(meta: doc.meta, segments: doc.segments)
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

    static func markdown(meta: SessionMeta, segments: [TranscriptSegment]) -> String {
        var out = "# Transcript — \(humanStamp.string(from: meta.date))\n\n"
        out += "- **Source:** \(meta.sourceLabel)\n"
        out += "- **Model:** \(meta.modelName)\n"
        if let v = meta.videoFile {
            var line = "- **Screen recording:** \(v)"
            if let t = meta.targetLabel { line += " — \(t)" }
            if let w = meta.videoWidth, let h = meta.videoHeight { line += " (\(w)×\(h))" }
            out += line + "\n"
        } else if let t = meta.targetLabel {
            out += "- **Capture target:** \(t)\n"
        }
        out += "\n---\n\n"

        let lines = segments.compactMap { seg -> String? in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Diarized sessions prefix a resolved speaker label AFTER the [mm:ss] anchor, so
            // click-to-seek, SearchIndex parsing, and stripLeadingTimestamp all keep working.
            // No speaker (feature off / pre-Stage-1 session) → byte-identical to before.
            let label = seg.speaker.map { "**\(meta.speakerLabel($0)):** " } ?? ""
            return "[\(timestamp(seg.start))] \(label)\(text)\n"
        }
        if lines.isEmpty {
            out += "_(no speech detected)_\n"
            return out
        }
        out += lines.joined(separator: "\n")
        return out
    }

    // MARK: HTML (self-contained)

    static func html(meta: SessionMeta, segments: [TranscriptSegment]) -> String {
        var body = ""
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let label = seg.speaker.map { "<b>\(escape(meta.speakerLabel($0))):</b> " } ?? ""
            body += "<p><span class=\"ts\">\(timestamp(seg.start))</span> \(label)\(escape(text))</p>\n"
        }

        var meta1 = "<li><b>Source:</b> \(escape(meta.sourceLabel))</li><li><b>Model:</b> \(escape(meta.modelName))</li>"
        if let v = meta.videoFile { meta1 += "<li><b>Screen recording:</b> \(escape(v))</li>" }
        if let t = meta.targetLabel { meta1 += "<li><b>Capture target:</b> \(escape(t))</li>" }

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
        </style></head><body>
        <h1>Transcript — \(escape(humanStamp.string(from: meta.date)))</h1>
        <ul class="meta">\(meta1)</ul><hr>
        \(body)
        </body></html>
        """
    }

    // MARK: - Internal

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
