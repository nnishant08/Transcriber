import Foundation

// MARK: - Document model (shared by capture, OCR, builder, exporter)

/// One recognised word, timed on the same pause-compressed `SessionClock` timeline as the segment
/// that contains it (Phase 3, Wave 1).
///
/// **Where these come from.** The Parakeet provider gets them free from `ASRResult.tokenTimings` —
/// no DTW, no forced alignment, no second model, on both the batch and the streaming path. Whisper
/// can produce them too, but only on request (`DecodingOptions.wordTimestamps`, off by default) and
/// only by running a DTW alignment that costs real time, so Said asks for them on the FINAL pass
/// and never on the live one, where the latency would land on the critical path.
///
/// So `words` is absent for every session recorded before Phase 3, for any Whisper model whose
/// alignment heads cannot serve the request, and for the live-save half of every session. Absence
/// is the ordinary case, not an error case — which is the whole reason for `validWords` below.
///
/// `confidence` is `nil` — never a sentinel like 0 or 1 — when the engine does not report one, so
/// "the engine was unsure" and "the engine did not say" stay distinguishable.
public struct WordTiming: Codable, Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let confidence: Float?

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// A spoken-transcript segment, timestamped relative to the session clock T0 (seconds).
/// `speaker` (1-based slot from diarization), `cleanedText` (Stage-1 cleanup pass), and
/// `redactedText` (Stage-2 PII/PHI redaction pass) and `words` (Phase-3 word timings) are all
/// optional and absent-by-default, so old `session.json` files decode unchanged and a session
/// recorded with those features off encodes byte-identically to before. Coding is written out by
/// hand rather than synthesized, because `words` must be omitted when EMPTY as well as when nil —
/// the synthesized `encodeIfPresent` would write `"words":[]` and dirty every session.
public struct TranscriptSegment: Sendable, Codable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var speaker: Int? = nil
    public var cleanedText: String? = nil
    /// Stage 2 (Feature C2): the redacted form of `text` with PII/PHI masked. The verbatim `text`
    /// and the `[mm:ss]` anchors are never touched; this is a parallel view, opt-in in the Viewer.
    public var redactedText: String? = nil
    /// Phase 3 (Wave 1): per-word timing + confidence, when the engine that produced this segment
    /// reported them. **Read this through `validWords`, never directly** — see that accessor for why.
    ///
    /// Normalized to `nil` rather than `[]` at construction and encoded only when non-empty, so a
    /// session transcribed by an engine with no word timings gains no `words` key at all.
    public var words: [WordTiming]? = nil

    public init(start: TimeInterval, end: TimeInterval, text: String, speaker: Int? = nil,
                cleanedText: String? = nil, redactedText: String? = nil,
                words: [WordTiming]? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.cleanedText = cleanedText
        self.redactedText = redactedText
        // Empty and absent mean the same thing here, and only one of them should ever reach disk.
        self.words = (words?.isEmpty ?? true) ? nil : words
    }

    enum CodingKeys: String, CodingKey {
        case start, end, text, speaker, cleanedText, redactedText, words
    }

    /// Decoded explicitly, and DEFENSIVELY on `words`, for the same reason `SessionDoc` decodes
    /// `frames` defensively: a `words` array of an unexpected shape — a bundle from a future build,
    /// a hand-edited file — must degrade to "this segment has no word timings" and leave the session
    /// readable, never throw and make it unopenable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(TimeInterval.self, forKey: .start)
        end = try c.decode(TimeInterval.self, forKey: .end)
        text = try c.decode(String.self, forKey: .text)
        speaker = try c.decodeIfPresent(Int.self, forKey: .speaker)
        cleanedText = try c.decodeIfPresent(String.self, forKey: .cleanedText)
        redactedText = try c.decodeIfPresent(String.self, forKey: .redactedText)
        let decoded = (try? c.decodeIfPresent([WordTiming].self, forKey: .words)) as? [WordTiming]
        words = (decoded?.isEmpty ?? true) ? nil : decoded
    }

    /// Encoded explicitly so `words` is written **only when non-empty**, exactly as
    /// `SessionDoc.frames` is. A session with no word timings therefore encodes byte-identically to
    /// pre-Phase-3 output — which is what keeps every existing session on disk untouched.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(speaker, forKey: .speaker)
        try c.encodeIfPresent(cleanedText, forKey: .cleanedText)
        try c.encodeIfPresent(redactedText, forKey: .redactedText)
        if let words, !words.isEmpty { try c.encode(words, forKey: .words) }
    }
}

// MARK: - The word-timing accessor discipline (Phase 3, Wave 1)

public extension TranscriptSegment {

    /// How far outside its own segment's bounds a word may sit before the array is judged
    /// mismatched rather than merely rounded.
    ///
    /// Engines derive a segment's `start`/`end` from the same token timings, so in practice they
    /// agree to within float noise; a quarter of a second absorbs any rounding an engine or a
    /// re-timing pass introduces, while an array belonging to a *different* segment is out by
    /// whole seconds and is still rejected.
    static var wordBoundsTolerance: TimeInterval { 0.25 }

    /// Validated word timings, or `nil`.
    ///
    /// **Every consumer goes through this, never through `words` directly.** Editing anchors edits
    /// to a word index, speaker alignment splits segments at a word boundary, redaction maps spans
    /// onto words, and semantic chunking cuts on word times — each of those silently corrupts a
    /// transcript if handed timings that are non-monotonic or belong to a different span. Making
    /// the *only* published reader a validating one is what keeps that class of bug impossible
    /// rather than merely unlikely; it is the same discipline `SessionDoc.visual` applies to the
    /// video-XOR-frames invariant, and for the same reason: the write path can be bypassed, but a
    /// display path cannot.
    ///
    /// Returns `nil` — never garbage, never a throw — when words are absent (every legacy session,
    /// and every session transcribed by an engine that does not report them), empty, non-monotonic,
    /// or outside the segment's own bounds. Absence is the ordinary case and is silent; genuinely
    /// malformed data logs, because that means something upstream is wrong and worth knowing about.
    var validWords: [WordTiming]? {
        guard let words, !words.isEmpty else { return nil }   // the ordinary case: silent
        for w in words where !(w.start.isFinite && w.end.isFinite && w.start <= w.end) {
            NSLog("[Words] rejected: word \"\(w.text)\" has a non-finite or inverted span "
                  + "(\(w.start)…\(w.end)) in segment [\(start)…\(end)]")
            return nil
        }
        for (a, b) in zip(words, words.dropFirst()) where b.start < a.start || b.end < a.end {
            NSLog("[Words] rejected: non-monotonic timings around \"\(a.text)\" → \"\(b.text)\" "
                  + "in segment [\(start)…\(end)]")
            return nil
        }
        let tol = Self.wordBoundsTolerance
        if let first = words.first, let last = words.last,
           first.start < start - tol || last.end > end + tol {
            NSLog("[Words] rejected: \(words.count) word(s) spanning \(first.start)…\(last.end) "
                  + "fall outside segment [\(start)…\(end)]")
            return nil
        }
        return words
    }

    /// True when this segment carries usable word-level timing. Cheap intent-revealing sugar over
    /// `validWords != nil` for the many call sites that only need to choose a granularity.
    var hasWordTimings: Bool { validWords != nil }
}

/// A still frame on the session's timeline — a slide photographed by the iPhone, with whatever text
/// Vision read off it (Phase 2).
///
/// **Deliberately three fields.** The removed Visual Capture feature carried capture modes, change
/// scores and dimensions because it decided *for itself* when to grab a frame. Nothing does that any
/// more: on the phone the shutter is a finger. A fourth field here would be the first step back
/// toward the feature that was cut.
///
/// **The Mac renders these; it never produces them.** Frames arrive on a Mac only inside a `.said`
/// bundle from a phone.
///
/// `time` is on `SessionClock`'s pause-compressed timeline — the same clock as bookmarks, segments
/// and screen-recording frames — which is what makes a frame line up with the audio it was taken
/// during.
public struct FrameEvent: Sendable, Codable, Equatable {
    public var time: TimeInterval
    /// Relative to the session folder, e.g. `images/slide-0004.png`, so the folder stays movable.
    public var imagePath: String
    /// Vision's reading of the slide. `nil` — never `""` — when OCR found nothing or wasn't run.
    public var text: String?

    public init(time: TimeInterval, imagePath: String, text: String? = nil) {
        self.time = time
        self.imagePath = imagePath
        self.text = text
    }
}

/// Which visual timeline a session has. A session has a video OR frames, never both (Phase 2, §P3);
/// this type is where that invariant is resolved so no display code ever has to reconcile two
/// visual timelines against one clock.
public enum VisualTimeline: Sendable, Equatable {
    case none
    case video(String)
    case frames([FrameEvent])
}

/// A user-dropped marker captured live (⌥⌘B) or added in the Viewer, in seconds from session T0.
public struct Bookmark: Sendable, Codable, Identifiable, Hashable {
    public var time: TimeInterval
    public var label: String?
    public var id: String { String(format: "bm-%.3f", time) }

    public init(time: TimeInterval, label: String? = nil) {
        self.time = time
        self.label = label
    }
}

/// A topic segment of the session with a start time (seconds from T0), shown as a clickable jump point.
public struct Chapter: Sendable, Codable, Identifiable, Hashable {
    public var start: TimeInterval
    public var title: String
    public var id: String { String(format: "ch-%.3f", start) }

    public init(start: TimeInterval, title: String) {
        self.start = start
        self.title = title
    }
}

/// A cached, on-device-generated artifact (Feature A — Generation Studio). Stored in
/// `SessionMeta.generatedArtifacts` keyed by template id, so reopening a session shows prior output
/// without re-running the model. `content` is the rendered text for text templates, or a JSON
/// encoding of the `@Generable` value for structured ones (so the Viewer can render it richly).
public struct GeneratedArtifact: Sendable, Codable, Hashable {
    public var templateId: String
    public var format: String          // "text" or "json"
    public var content: String
    public var createdAt: Date

    public init(templateId: String, format: String, content: String, createdAt: Date) {
        self.templateId = templateId
        self.format = format
        self.content = content
        self.createdAt = createdAt
    }
}

public struct SessionMeta: Sendable, Codable {
    /// A stable identity for this session that survives export, import, and being carried between
    /// devices (Phase 1, D1). Optional and `decodeIfPresent` + `encodeIfPresent`, so a `session.json`
    /// written before this field existed decodes unchanged AND is not rewritten merely by reading it.
    /// New sessions get one at creation; pre-existing folders are backfilled lazily off the save path
    /// (`SessionStore.ensureSessionID`), exactly like the title backfill.
    ///
    /// Nothing in Phase 1 reads it except the `.said` bundle's collision rule. It exists now because
    /// retrofitting an identity onto thousands of folders later is strictly worse than adding it
    /// while the schema is already being touched.
    public var id: UUID?
    public var date: Date
    public var sourceLabel: String
    var modelName: String
    var targetLabel: String?
    var modeLabel: String?
    // Unified session store (Prompt 1): auto-generated title + tags, plus a schema marker.
    // All optional/defaulted and decoded with `decodeIfPresent`, so a `session.json` written before
    // these fields existed (older visual / Prompt-1 sessions) still decodes cleanly.
    public var title: String?
    public var tags: [String]
    public var schemaVersion: Int
    // Prompt 2 (Chat & Intelligence / Capture / UX): generated artifacts + saved-audio reference,
    // all backward-compatible (decodeIfPresent → sensible empty defaults).
    public var audioFile: String?                 // relative filename of saved playback audio (e.g. "audio.m4a")
    public var durationSeconds: Double?           // recording/import length, for the player + SRT bounds
    public var bookmarks: [Bookmark]
    public var chapters: [Chapter]
    public var actionItems: [String]
    public var summaries: [String: String]        // SummaryStyle.rawValue (or "custom:<name>") → cached summary
    public var imported: Bool                      // true for drag-drop / Import sessions
    // Stage 1 (diarization / multilingual): all optional + decodeIfPresent → old session.json decodes
    // unchanged, and sessions recorded with the features off omit the keys entirely.
    public var speakerCount: Int?                  // distinct diarized speakers (nil = never diarized)
    public var speakerNames: [String: String]?     // speaker slot ("1") → user-chosen name ("Alice")
    public var language: String?                   // resolved transcription language when not the default "en"
    // Stage 2: all optional + decodeIfPresent → old session.json decodes unchanged, and sessions
    // produced with these features untouched omit the keys entirely (byte-identical default encoding).
    public var generatedArtifacts: [String: GeneratedArtifact]?  // Feature A: template id → cached output
    public var retentionLocked: Bool?              // Feature C1: true exempts the session from auto-delete
    // Screen recording: the session's video, on the same pause-compressed clock as the transcript.
    // Relative filename so the folder stays self-contained and movable — "screen.mp4" for a recorded
    // session, the copied original for an imported video. Absent (nil) for audio-only sessions, so
    // their session.json is unchanged.
    public var videoFile: String?
    var videoWidth: Int?
    public var videoHeight: Int?
    // Phase 3 (Wave 2): which ASR engine produced this transcript, and which of its models.
    // `decodeIfPresent` + synthesized `encodeIfPresent`, so every session written before Phase 3
    // decodes unchanged and gains no keys. A user must be able to tell what wrote their words —
    // especially once two engines can, and once "re-transcribe on the other one" is an option.
    public var engine: String?          // TranscriptionEngineID.rawValue: "whisper" | "parakeet"
    public var engineModel: String?     // e.g. "openai_whisper-base.en", "v3"
    /// Phase 3 (Wave 4): cross-session speaker matches the post-save pass PROPOSED. Never an
    /// assignment — `speakerNames` is only written once the user confirms in the Viewer. Absent
    /// entirely when the voiceprint feature is off, which is the default.
    public var voiceprintProposals: [VoiceprintProposal]?

    /// **Phase 3 diverges from its build prompt here, deliberately.** The prompt asked for a new
    /// `SessionDoc.schemaVersion` defaulting to 1, with this build writing 2. `SessionMeta` already
    /// carried exactly that marker, already at 2, and a document with two disagreeing version
    /// numbers is worse than one with a version number that moves — so the existing field is
    /// reused and bumped instead.
    ///
    /// The ladder: **absent (decoded as 0)** = pre-unified-store; **2** = unified store through
    /// Phase 2; **3** = Phase 3, i.e. a session that may carry `words` and `slides`.
    ///
    /// Only a *newly constructed* meta takes this value. A legacy session decodes at its own
    /// version and is re-encoded at that version, so a title backfill or a diarization pass can
    /// never silently upgrade a session it merely touched — asserted by `--selftest-words`.
    public static let currentSchemaVersion = 3

    public init(id: UUID? = nil, date: Date, sourceLabel: String, modelName: String,
         targetLabel: String? = nil, modeLabel: String? = nil,
         title: String? = nil, tags: [String] = [], schemaVersion: Int = SessionMeta.currentSchemaVersion,
         audioFile: String? = nil, durationSeconds: Double? = nil,
         bookmarks: [Bookmark] = [], chapters: [Chapter] = [], actionItems: [String] = [],
         summaries: [String: String] = [:], imported: Bool = false,
         speakerCount: Int? = nil, speakerNames: [String: String]? = nil, language: String? = nil,
         generatedArtifacts: [String: GeneratedArtifact]? = nil, retentionLocked: Bool? = nil,
         videoFile: String? = nil, videoWidth: Int? = nil, videoHeight: Int? = nil,
         engine: String? = nil, engineModel: String? = nil,
         voiceprintProposals: [VoiceprintProposal]? = nil) {
        self.id = id
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
        self.engine = engine
        self.engineModel = engineModel
        self.voiceprintProposals = voiceprintProposals
    }

    enum CodingKeys: String, CodingKey {
        case id
        case date, sourceLabel, modelName, targetLabel, modeLabel, title, tags, schemaVersion
        case audioFile, durationSeconds, bookmarks, chapters, actionItems, summaries, imported
        case speakerCount, speakerNames, language
        case generatedArtifacts, retentionLocked
        case videoFile, videoWidth, videoHeight
        case engine, engineModel, voiceprintProposals
    }

    // Custom decode for backward compatibility: older session.json files lack the newer fields.
    // (Swift's synthesized Decodable does NOT fall back to property defaults for missing keys, so we
    // must decodeIfPresent the new fields explicitly.) `encode(to:)` stays synthesized via CodingKeys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
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
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        engineModel = try c.decodeIfPresent(String.self, forKey: .engineModel)
        voiceprintProposals = try c.decodeIfPresent([VoiceprintProposal].self, forKey: .voiceprintProposals)
    }

    /// True when this session has a video to play alongside the transcript.
    public var hasVideo: Bool { videoFile?.isEmpty == false }

    /// "Parakeet · v3", or nil for a session recorded before Phase 3. Shown in the Viewer so the
    /// question "why does this transcript read differently from that one" has a visible answer.
    public var engineLabel: String? {
        guard let engine, let id = TranscriptionEngineID(rawValue: engine) else { return nil }
        guard let engineModel, !engineModel.isEmpty else { return id.displayName }
        return "\(id.displayName) · \(engineModel)"
    }

    /// Display name for a diarized speaker slot: the user's rename when present, else "Speaker N".
    public func speakerLabel(_ slot: Int) -> String {
        if let name = speakerNames?[String(slot)]?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        return "Speaker \(slot)"
    }
}

/// The full session document — written as `session.json` so the folder is self-describing
/// (the exporter rebuilds HTML/PDF from this without re-parsing Markdown).
public struct SessionDoc: Sendable, Codable {
    public var meta: SessionMeta
    public var segments: [TranscriptSegment]
    /// Still frames on the timeline (Phase 2). Empty for every session the Mac records — the Mac
    /// renders frames but never captures them — so an audio-only `session.json` gains no key.
    public var frames: [FrameEvent]
    /// Slide SPANS derived from `frames` (Phase 3, Wave 5): "slide 4 was up from 12:03 to 18:40".
    ///
    /// A materialised view, refreshed by `writeSession` on every write and never edited
    /// independently — `frames` stays the single source of truth. Cached rather than always
    /// recomputed because the Library draws a row per session and re-segmenting every one of them
    /// on every keystroke of a search is work with no payoff. Read it through `slideSpans`, which
    /// falls back to deriving when the cache is absent.
    public var slides: [SlideSpan]?

    public init(meta: SessionMeta, segments: [TranscriptSegment], frames: [FrameEvent] = [],
                slides: [SlideSpan]? = nil) {
        self.meta = meta
        self.segments = segments
        self.frames = frames
        self.slides = slides
    }

    enum CodingKeys: String, CodingKey { case meta, segments, frames, slides }

    /// Decoded explicitly, and DEFENSIVELY on `frames`.
    ///
    /// There are real sessions on disk carrying a `frames` array written by the removed Visual
    /// Capture feature, whose elements were `{sessionTime, imagePath, ocrText}` — a shape that does
    /// not decode into today's `{time, imagePath, text}` (`time` is non-optional, so it throws).
    /// A legacy array must therefore yield an EMPTY array and a readable session, never an error
    /// that makes an old session unopenable. Verified by `--selftest-frames`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(SessionMeta.self, forKey: .meta)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        frames = (try? c.decodeIfPresent([FrameEvent].self, forKey: .frames)) as? [FrameEvent] ?? []
        // Defensive for the same reason `frames` is: a cache written by another build must degrade
        // to "recompute it", never to an unopenable session.
        slides = (try? c.decodeIfPresent([SlideSpan].self, forKey: .slides)) as? [SlideSpan]
    }

    /// Encoded only when non-empty, so a session with no frames produces `session.json` with no
    /// `frames` key at all — byte-identical to pre-Phase-2 output.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(meta, forKey: .meta)
        try c.encode(segments, forKey: .segments)
        if !frames.isEmpty { try c.encode(frames, forKey: .frames) }
        if let slides, !slides.isEmpty { try c.encode(slides, forKey: .slides) }
    }

    /// The session's slide spans: the cache when it is there, freshly derived when it is not.
    /// A session with no frames has none, and gains no keys.
    public var slideSpans: [SlideSpan] {
        if let slides, !slides.isEmpty { return slides }
        guard !frames.isEmpty else { return [] }
        return SlideSegmenter.spans(frames: frames, sessionDuration: meta.durationSeconds)
    }

    /// The session's ONE visual timeline (Phase 2, §P3 invariant).
    ///
    /// Enforced here, in a validating accessor, rather than only at the write path: the write path
    /// can be bypassed (a hand-edited `session.json`, a bundle from a future build, a legacy
    /// folder), whereas every display path has to come through this. If a session somehow has both,
    /// **video wins** — it is the larger artifact and the one with a continuous timeline — and the
    /// condition is logged rather than silently resolved.
    public var visual: VisualTimeline {
        let hasVideo = meta.videoFile?.isEmpty == false
        if hasVideo && !frames.isEmpty {
            NSLog("[Session] invariant violated: both videoFile and \(frames.count) frame(s) present; video wins")
        }
        if let v = meta.videoFile, !v.isEmpty { return .video(v) }
        if !frames.isEmpty { return .frames(frames) }
        return .none
    }
}

// MARK: - DocumentBuilder

/// Renders a session's timestamped transcript to Markdown / HTML.
///
/// Everything in a session is measured on ONE clock: `T0`, captured at recording start with
/// `CACurrentMediaTime()` and compressed by any paused time. WhisperKit's segment timestamps are
/// relative to the audio buffer, which starts at T0, and the screen recording's frames are stamped
/// on the same compressed clock — so `[mm:ss]`, the audio, and the video all line up for free.
public enum DocumentBuilder {

    public static func timestamp(_ t: TimeInterval) -> String {
        let total = Int(max(0, t).rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Session folder layout

    /// A per-session folder `~/Desktop/Transcripts/<yyyy-MM-dd HH-mm-ss>/`. Self-contained and
    /// movable: `transcript.md` + `session.json`, plus `audio.m4a` / `screen.mp4` when those exist.
    public static func makeSessionFolder(date: Date, root: URL = SessionLocation.root) -> URL {
        let dir = root
            .appendingPathComponent(folderStamp.string(from: date), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write `transcript.md` + machine-readable `session.json` into the session folder.
    public static func writeSession(_ doc: SessionDoc, to sessionDir: URL) {
        // `visual` is consulted for its side effect: it logs if the video-XOR-frames invariant is
        // violated, so a bad session is noisy at the write path as well as at every display path.
        _ = doc.visual
        // Refresh the derived slide spans so the cache can never be stale relative to the frames it
        // is a view of. Deriving costs nothing for the overwhelmingly common case of no frames.
        var doc = doc
        doc.slides = doc.frames.isEmpty
            ? nil
            : SlideSegmenter.spans(frames: doc.frames, sessionDuration: doc.meta.durationSeconds)
        let md = markdown(meta: doc.meta, segments: doc.segments, frames: doc.frames)
        // Route through SessionIO so encryption-at-rest (Feature C4) is transparent. When encryption
        // is OFF (default) this is a byte-identical plain UTF-8 write — same bytes as before.
        try? SessionIO.writeText(md, to: sessionDir.appendingPathComponent("transcript.md"))
        writeSessionJSON(doc, to: sessionDir)
    }

    /// Write ONLY `session.json`, leaving `transcript.md` untouched. Used by (a) migration, which must
    /// preserve the original transcript bytes copied in as transcript.md, and (b) title/tag backfill,
    /// which only updates `meta` and must not re-render (and possibly reformat) the transcript.
    public static func writeSessionJSON(_ doc: SessionDoc, to sessionDir: URL) {
        if let json = try? JSONEncoder().encode(doc) {
            // Atomic (so a concurrent reader never sees a torn file) + routed through SessionIO for
            // transparent encryption-at-rest. OFF (default) ⇒ byte-identical plain write.
            try? SessionIO.writeData(json, to: sessionDir.appendingPathComponent("session.json"))
        }
    }

    public static func readSession(_ sessionDir: URL) -> SessionDoc? {
        guard let data = try? SessionIO.readData(sessionDir.appendingPathComponent("session.json")) else { return nil }
        return try? JSONDecoder().decode(SessionDoc.self, from: data)
    }

    // MARK: Markdown

    /// One entry on the merged transcript timeline.
    private enum TimelineItem {
        case text(TranscriptSegment)
        case frame(FrameEvent)
    }

    /// Merge segments and frames by time. On a tie, TEXT comes before the frame — matching the
    /// removed feature's ordering, so a transcript re-rendered from an old session is unchanged.
    private static func timeline(segments: [TranscriptSegment], frames: [FrameEvent]) -> [TimelineItem] {
        var items: [(time: TimeInterval, order: Int, item: TimelineItem)] = []
        for s in segments { items.append((s.start, 0, .text(s))) }
        for f in frames { items.append((f.time, 1, .frame(f))) }
        items.sort { $0.time != $1.time ? $0.time < $1.time : $0.order < $1.order }
        return items.map(\.item)
    }

    public static func markdown(meta: SessionMeta, segments: [TranscriptSegment],
                                frames: [FrameEvent] = []) -> String {
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

        // Each block ends in exactly one "\n" and blocks are joined by "\n", so consecutive entries
        // are separated by a blank line. Keeping that discipline — rather than appending "\n\n" per
        // item — is what makes the no-frames output BYTE-IDENTICAL to pre-Phase-2, which
        // `--selftest-doc`'s md5 assertion proves.
        let blocks = timeline(segments: segments, frames: frames).compactMap { item -> String? in
            switch item {
            case .text(let seg):
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                // Diarized sessions prefix a resolved speaker label AFTER the [mm:ss] anchor, so
                // click-to-seek, SearchIndex parsing, and stripLeadingTimestamp all keep working.
                // No speaker (feature off / pre-Stage-1 session) → byte-identical to before.
                let label = seg.speaker.map { "**\(meta.speakerLabel($0)):** " } ?? ""
                return "[\(timestamp(seg.start))] \(label)\(text)\n"

            case .frame(let f):
                // The form the removed feature emitted, matched exactly, because transcripts on disk
                // were written this way and every reader still expects it. The `[mm:ss]` anchor lives
                // in the image's ALT TEXT rather than leading the line — which works because
                // `SearchIndex.extractSnippets` runs `firstTimestamp(in:)` BEFORE it skips `![`
                // lines, so a hit in the OCR text below still carries this frame's timestamp.
                let ts = timestamp(f.time)
                var block = "![\(ts)](\(f.imagePath))\n"
                if let ocr = f.text?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
                    block += "\n<details><summary>On-slide text (\(ts))</summary>\n\n```\n\(ocr)\n```\n\n</details>\n"
                }
                return block
            }
        }
        if blocks.isEmpty {
            out += "_(no speech detected)_\n"
            return out
        }
        out += blocks.joined(separator: "\n")
        return out
    }

    // MARK: HTML (self-contained)

    /// - Parameter imageData: resolves a frame's relative `imagePath` to PNG bytes, so the export
    ///   stays a SINGLE self-contained file (images embedded as base64 data URIs). Sessions with no
    ///   frames never call it, and the output is unchanged from before Phase 2.
    static func html(meta: SessionMeta, segments: [TranscriptSegment],
                     frames: [FrameEvent] = [],
                     imageData: (String) -> Data? = { _ in nil }) -> String {
        var body = ""
        for item in timeline(segments: segments, frames: frames) {
            switch item {
            case .text(let seg):
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let label = seg.speaker.map { "<b>\(escape(meta.speakerLabel($0))):</b> " } ?? ""
                body += "<p><span class=\"ts\">\(timestamp(seg.start))</span> \(label)\(escape(text))</p>\n"

            case .frame(let f):
                let ts = timestamp(f.time)
                if let data = imageData(f.imagePath) {
                    let uri = "data:image/png;base64,\(data.base64EncodedString())"
                    body += "<figure class=\"slide\"><img src=\"\(uri)\" alt=\"Slide at \(ts)\"/>"
                    body += "<figcaption><span class=\"ts\">\(ts)</span></figcaption></figure>\n"
                } else {
                    body += "<p class=\"ts\">[slide image \(ts) missing]</p>\n"
                }
                if let ocr = f.text?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
                    body += "<details class=\"ocr\"><summary>On-slide text (\(ts))</summary><pre>\(escape(ocr))</pre></details>\n"
                }
            }
        }

        var meta1 = "<li><b>Source:</b> \(escape(meta.sourceLabel))</li><li><b>Model:</b> \(escape(meta.modelName))</li>"
        if let v = meta.videoFile { meta1 += "<li><b>Screen recording:</b> \(escape(v))</li>" }
        if !frames.isEmpty { meta1 += "<li><b>Slides:</b> \(frames.count)</li>" }
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
          /* Frames, on the current Said identity tokens (violet #6949D2 / amber #EEA753 /
             ink #1A1828 / rule #D5D3F7) — NOT the pre-rebrand greys the surrounding CSS uses. */
          figure.slide { margin: 22px 0; padding: 0; background: #fff; border-radius: 12px;
                         box-shadow: 0 3px 0 #D5D3F7; overflow: hidden; }
          figure.slide img { display: block; width: 100%; height: auto; }
          figure.slide figcaption { padding: 8px 13px; background: #FFE0B0; }
          figure.slide figcaption .ts { color: #794900; font-weight: 600; margin: 0;
                                        font-family: ui-monospace, "SF Mono", Menlo, monospace; }
          details.ocr { margin: -14px 0 22px; padding: 10px 13px; border-left: 3px solid #6949D2;
                        background: #F1F0FF; border-radius: 0 8px 8px 0; }
          details.ocr summary { cursor: pointer; color: #6949D2; font-size: 12px; font-weight: 600;
                                font-family: ui-monospace, "SF Mono", Menlo, monospace;
                                text-transform: uppercase; letter-spacing: .08em; }
          details.ocr pre { margin: 8px 0 0; white-space: pre-wrap; font-size: 13px; color: #1A1828;
                            font-family: ui-monospace, "SF Mono", Menlo, monospace; }
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
