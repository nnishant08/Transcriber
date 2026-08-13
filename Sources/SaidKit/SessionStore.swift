import Foundation

extension Notification.Name {
    /// Posted (on the main actor) whenever a session folder is created or updated on disk, so open
    /// windows (the Library) and the search index can refresh. `userInfo["dir"]` is the folder URL
    /// when known (nil for a bulk refresh).
    public static let transcriberSessionSaved = Notification.Name("transcriberSessionSaved")
}

/// A lightweight, listing-friendly view of one on-disk session folder (`transcript.md` +
/// `session.json` [+ `audio.m4a` / `screen.mp4`]). Built by `SessionStore.allSessions()` for the Library.
public struct SessionInfo: Identifiable, Sendable {
    public let dir: URL
    public let meta: SessionMeta
    public let snippet: String

    public var id: String { dir.path }
    /// The session has a video (a screen recording, or an imported video) to play with the transcript.
    public var hasVideo: Bool { meta.hasVideo }
    public var date: Date { meta.date }

    /// The stored title (re-sanitized as a display guard against any historically messy value),
    /// or a model-free fallback derived from the snippet/date.
    public var displayTitle: String {
        if let raw = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let cleaned = TitleGenerator.sanitizeTitle(raw)
            if !cleaned.isEmpty { return cleaned }
        }
        return TitleGenerator.fallbackTitle(transcript: snippet, date: meta.date)
    }
}

/// Outcome of a migration pass (non-destructive, idempotent).
public struct MigrationResult: Sendable {
    public var migratedCount: Int
    public var backupURL: URL?
    public var legacyFound: Int
    public var summary: String
}

/// The unified on-disk session store. Every session is a folder under `~/Desktop/Transcripts`
/// containing `transcript.md` + `session.json` (+ the media it produced: `audio.m4a`, `screen.mp4`). This enum is the
/// single place that lists sessions, migrates legacy flat `*.md` files, derives plain text /
/// snippets, and backfills titles/tags — reused by the Library, the search index, and self-tests.
public enum SessionStore {

    /// The session root (C1 seam — `~/Desktop/Transcripts` on macOS, the app container on iOS).
    public static var root: URL { SessionLocation.root }

    // MARK: - Listing

    /// All session folders under `root` (a directory containing a `transcript.md`), as URLs.
    public static func sessionDirectoryURLs(root: URL = SessionStore.root) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { url in
            ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) &&
            fm.fileExists(atPath: url.appendingPathComponent("transcript.md").path)
        }
    }

    /// All sessions as `SessionInfo`, newest first. Reads `session.json` (or synthesizes meta when a
    /// folder somehow lacks one) and a one-line snippet from `transcript.md`.
    public static func allSessions(root: URL = SessionStore.root) -> [SessionInfo] {
        var infos: [SessionInfo] = []
        for dir in sessionDirectoryURLs(root: root) {
            let meta = DocumentBuilder.readSession(dir)?.meta ?? synthMeta(dir: dir)
            let snip = snippet(plainText: transcriptPlainText(dir: dir))
            infos.append(SessionInfo(dir: dir, meta: meta, snippet: snip))
        }
        infos.sort { $0.meta.date > $1.meta.date }
        return infos
    }

    /// Synthesize a neutral meta for a folder with no readable `session.json` (date from folder name,
    /// else mtime). Does NOT guess the source.
    public static func synthMeta(dir: URL) -> SessionMeta {
        let date = DocumentBuilder.folderStamp.date(from: dir.lastPathComponent)
            ?? fileModificationDate(dir) ?? Date()
        return SessionMeta(date: date, sourceLabel: "Unknown", modelName: "")
    }

    // MARK: - Plain text / snippets (markdown → readable text)

    /// Read `transcript.md` and strip it to readable plain text (drops the metadata header, `[mm:ss]`
    /// prefixes, image lines, and `<details>`/code fences while keeping OCR text). Used for title
    /// generation and snippets. Returns "" if the file is missing.
    public static func transcriptPlainText(dir: URL) -> String {
        guard let raw = SessionIO.readText(dir.appendingPathComponent("transcript.md")) else { return "" }
        return plainText(fromMarkdown: raw)
    }

    public static func plainText(fromMarkdown raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        // Drop the metadata header up to and including the first horizontal rule.
        if let sep = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeFirst(sep + 1)
        }
        var out: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("```") { continue }                              // keep OCR content, drop fences
            if t.hasPrefix("#") || t.hasPrefix("![") || t.hasPrefix("- **")
                || t.hasPrefix("<details") || t.hasPrefix("</details") || t.hasPrefix("<summary") { continue }
            out.append(stripLeadingSpeakerLabel(stripLeadingTimestamp(t)))
        }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip a leading `**Speaker 1:** ` label (diarized transcript lines) for snippets/titling.
    /// Kept in `timestampedTranscript` on purpose — chat grounding benefits from knowing who spoke.
    public static func stripLeadingSpeakerLabel(_ s: String) -> String {
        guard s.hasPrefix("**"), let close = s.range(of: ":**") else { return s }
        let label = s[s.index(s.startIndex, offsetBy: 2)..<close.lowerBound]
        guard !label.isEmpty, label.count <= 40, !label.contains("*") else { return s }
        return String(s[close.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// The transcript body as timestamped lines — `[mm:ss] text` speech lines plus slide OCR text —
    /// with the metadata header and markdown chrome stripped. This is the grounding context fed to
    /// chat / summary / chapters so the model can cite `[mm:ss]`. (Legacy sessions without in-body
    /// timestamps degrade to plain lines.) Clipped to `maxChars` to respect the model's context window.
    public static func timestampedTranscript(dir: URL, maxChars: Int = 12_000) -> String {
        guard let raw = SessionIO.readText(dir.appendingPathComponent("transcript.md")) else { return "" }
        var lines = raw.components(separatedBy: "\n")
        if let sep = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeFirst(sep + 1)
        }
        var out: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("#") || t.hasPrefix("- **") || t.hasPrefix("```")
                || t.hasPrefix("<details") || t.hasPrefix("</details") || t.hasPrefix("<summary") { continue }
            if t.hasPrefix("![") {                       // slide image line → keep just its timestamp marker
                if let ts = firstTimestamp(in: t) { out.append("[\(ts)] (slide)") }
                continue
            }
            out.append(t)                                // keep "[mm:ss] text" speech + OCR text verbatim
        }
        var result = out.joined(separator: "\n")
        if result.count > maxChars { result = String(result.prefix(maxChars)) }
        return result
    }

    /// Timed transcript segments for a session — `session.json` segments when present (full per-word
    /// timing), else derived from the `[mm:ss]` speech markers in `transcript.md` (each cue ends where
    /// the next begins; 1 s granularity). Returns [] when there is no usable timing (e.g. a legacy
    /// session whose body has no timestamps) so subtitle export can skip gracefully.
    public static func timedSegments(dir: URL) -> [TranscriptSegment] {
        if let doc = DocumentBuilder.readSession(dir), !doc.segments.isEmpty {
            return doc.segments
        }
        // Derive from transcript.md [mm:ss] lines.
        guard let raw = SessionIO.readText(dir.appendingPathComponent("transcript.md")) else { return [] }
        var lines = raw.components(separatedBy: "\n")
        if let sep = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeFirst(sep + 1)
        }
        var derived: [(start: TimeInterval, text: String)] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), let ts = firstTimestamp(in: t), t.hasPrefix("[\(ts)]") else { continue }
            let text = stripLeadingTimestamp(t)
            guard !text.isEmpty else { continue }
            derived.append((secondsFrom(ts), text))
        }
        guard !derived.isEmpty else { return [] }
        var segs: [TranscriptSegment] = []
        for (i, d) in derived.enumerated() {
            // End at the next marker (half-open, never overlapping); clamp to [start, start+4].
            let end = i + 1 < derived.count ? max(d.start, min(d.start + 4, derived[i + 1].start)) : d.start + 4
            segs.append(TranscriptSegment(start: d.start, end: end, text: d.text))
        }
        return segs
    }

    /// "mm:ss" / "h:mm:ss" → seconds.
    static func secondsFrom(_ ts: String) -> TimeInterval {
        let p = ts.split(separator: ":").compactMap { Int($0) }
        switch p.count {
        case 2: return TimeInterval(p[0] * 60 + p[1])
        case 3: return TimeInterval(p[0] * 3600 + p[1] * 60 + p[2])
        default: return 0
        }
    }

    /// First ~160 chars of plain text, cut on a word boundary.
    public static func snippet(plainText text: String, max: Int = 160) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        var cut = String(t.prefix(max))
        if let sp = cut.lastIndex(of: " ") { cut = String(cut[..<sp]) }
        return cut + "…"
    }

    /// The first `mm:ss` (1–2 digit minutes) appearing in a line, e.g. from `[00:05]`, `![00:05](…)`,
    /// or `(00:05)`. Returns nil if none.
    public static func firstTimestamp(in line: String) -> String? {
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if chars[i].isNumber {
                var j = i
                while j < chars.count, chars[j].isNumber { j += 1 }
                let minDigits = j - i
                if j < chars.count, chars[j] == ":" {
                    var k = j + 1, sec = 0
                    while k < chars.count, chars[k].isNumber, sec < 2 { k += 1; sec += 1 }
                    // 1–3 minute digits so "100:05" (≥100 min, the format `timestamp(_:)` emits) is matched.
                    if (1...3).contains(minDigits), sec == 2 { return String(chars[i..<k]) }
                }
                i = j
            } else { i += 1 }
        }
        return nil
    }

    /// Strip a leading `[mm:ss] ` timestamp from a transcript line.
    public static func stripLeadingTimestamp(_ s: String) -> String {
        guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return s }
        let inside = String(s[s.index(after: s.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
        guard firstTimestamp(in: inside) == inside else { return s }
        return String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Title / tag backfill

    /// Ensure `session.json` has a non-empty title (generating title+tags on-device if missing).
    /// Idempotent: returns immediately if a title already exists unless `force`. Updates only
    /// `session.json` (never re-renders transcript.md), then notifies + re-indexes. Never throws.
    public static func ensureTitle(dir: URL, force: Bool = false) async {
        guard var doc = DocumentBuilder.readSession(dir) else { return }
        if !force, let raw = doc.meta.title?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            // Already titled. If the stored value has cosmetic cruft (e.g. a leaked "**Title:**"
            // markdown label from an older build), repair it WITHOUT a model call; else we're done.
            let cleaned = TitleGenerator.sanitizeTitle(raw)
            guard !cleaned.isEmpty, cleaned != raw else { return }
            doc.meta.title = cleaned
            DocumentBuilder.writeSessionJSON(doc, to: dir)
            SearchIndex.shared.index(sessionDir: dir)
            postSessionSaved(dir)
            return
        }
        let text = transcriptPlainText(dir: dir)
        let result = await TitleGenerator.generate(transcript: text, date: doc.meta.date)
        doc.meta.title = result.title
        doc.meta.tags = result.tags
        DocumentBuilder.writeSessionJSON(doc, to: dir)
        SearchIndex.shared.index(sessionDir: dir)
        postSessionSaved(dir)
    }

    /// Give a session folder a stable `SessionMeta.id` if it doesn't already have one (D1).
    ///
    /// Deliberately the same shape as `ensureTitle`: off the save path, `writeSessionJSON` ONLY (so
    /// `transcript.md` is never re-rendered), and serialized behind the same post-save `Task.detached`
    /// chain so it cannot race the title / diarization / cleanup passes' read-modify-write of
    /// `session.json`.
    ///
    /// A session that already has an id is left completely untouched — no write, no notification —
    /// so merely listing the Library never rewrites a file.
    @discardableResult
    public static func ensureSessionID(dir: URL) -> UUID? {
        guard var doc = DocumentBuilder.readSession(dir) else { return nil }
        if let existing = doc.meta.id { return existing }
        let fresh = UUID()
        doc.meta.id = fresh
        DocumentBuilder.writeSessionJSON(doc, to: dir)
        return fresh
    }

    /// Fill tags for a titled session. By default only touches titled-but-untagged sessions (e.g.
    /// titled by an older build whose parser dropped a markdown-wrapped `TAGS:` line); `force` also
    /// regenerates sessions that already have tags. Keeps the existing title; only writes tags. Skips
    /// near-empty transcripts (e.g. pure `[BLANK_AUDIO]`). Retries once if the model returns no tags.
    /// Returns the tags written ([] = skipped/unchanged).
    @discardableResult
    public static func backfillTags(dir: URL, force: Bool = false) async -> [String] {
        guard var doc = DocumentBuilder.readSession(dir) else { return [] }
        let title = doc.meta.title?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !title.isEmpty else { return [] }
        if !force, !doc.meta.tags.isEmpty { return [] }
        let text = transcriptPlainText(dir: dir)
        guard meaningfulWordCount(text) >= 20 else { return [] }             // skip blank/silent sessions
        var tags: [String] = []
        for _ in 0..<2 {                                                     // focused tags-only prompt, retried
            tags = await TitleGenerator.generateTags(transcript: text)
            if !tags.isEmpty { break }
        }
        guard !tags.isEmpty else { return [] }
        doc.meta.tags = tags
        DocumentBuilder.writeSessionJSON(doc, to: dir)                       // title left untouched
        SearchIndex.shared.index(sessionDir: dir)
        postSessionSaved(dir)
        return tags
    }

    /// Word count excluding bracketed annotations like `[BLANK_AUDIO]`, `[ Silence ]`, `[INAUDIBLE]`.
    static func meaningfulWordCount(_ text: String) -> Int {
        var t = text
        while let open = t.firstIndex(of: "["), let close = t[open...].firstIndex(of: "]") {
            t.removeSubrange(open...close)
        }
        return t.split { $0 == " " || $0 == "\n" || $0 == "\t" }.filter { !$0.isEmpty }.count
    }

    /// Post the session-saved notification. Safe from any thread (NotificationCenter is thread-safe;
    /// the Library's observer is registered with `queue: .main`, so its refresh still runs on main).
    public static func postSessionSaved(_ dir: URL) {
        NotificationCenter.default.post(name: .transcriberSessionSaved, object: nil, userInfo: ["dir": dir])
    }

    // MARK: - Migration (legacy flat *.md → folder layout)

    /// Migrate legacy flat `*.md` files at the `root` into the unified folder layout. Non-destructive
    /// (one full backup of the Transcripts directory first; original removed only after a verified
    /// copy) and idempotent (a re-run finds no flat files → no backup, no duplicate folders).
    @discardableResult
    public static func migrateLegacyFlatFiles(root: URL = SessionStore.root) -> MigrationResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            return MigrationResult(migratedCount: 0, backupURL: nil, legacyFound: 0, summary: "no Transcripts directory")
        }
        // Legacy = *.md files directly at the root (new/visual sessions live in subfolders).
        let contents = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        let legacy = contents.filter { url in
            url.pathExtension.lowercased() == "md"
                && ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true)
        }
        guard !legacy.isEmpty else {
            return MigrationResult(migratedCount: 0, backupURL: nil, legacyFound: 0,
                                   summary: "no legacy flat files; nothing to migrate")
        }

        // 1) ONE timestamped backup of the entire Transcripts directory before touching anything.
        let backupURL = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)_backup_\(backupStamp.string(from: Date()))")
        do {
            try fm.copyItem(at: root, to: backupURL)
        } catch {
            return MigrationResult(migratedCount: 0, backupURL: nil, legacyFound: legacy.count,
                                   summary: "backup failed (\(error.localizedDescription)); migration skipped for safety")
        }

        var migrated = 0
        for file in legacy.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let base = file.deletingPathExtension().lastPathComponent
            let folder = root.appendingPathComponent(base, isDirectory: true)
            let destTranscript = folder.appendingPathComponent("transcript.md")

            // Interrupted prior run: folder already has transcript.md → just remove the stray flat file.
            if fm.fileExists(atPath: destTranscript.path) {
                try? fm.removeItem(at: file)
                continue
            }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try fm.copyItem(at: file, to: destTranscript)
                // Verify the copy (identical bytes) BEFORE removing the original.
                let orig = try Data(contentsOf: file)
                let copy = try Data(contentsOf: destTranscript)
                guard copy == orig else {
                    NSLog("[Migrate] verify failed for \(base); leaving original in place")
                    continue
                }
                let date = parseLegacyDate(base) ?? fileModificationDate(file) ?? Date()
                let meta = SessionMeta(date: date, sourceLabel: "Unknown", modelName: "")
                // Write ONLY session.json — must not re-render (and blank) the copied transcript.md.
                DocumentBuilder.writeSessionJSON(SessionDoc(meta: meta, segments: []), to: folder)
                try fm.removeItem(at: file)     // safe: copy verified above
                migrated += 1
            } catch {
                NSLog("[Migrate] failed for \(base): \(error)")
            }
        }

        let summary = "migrated \(migrated) legacy session\(migrated == 1 ? "" : "s"), backup at \(backupURL.path)"
        NSLog("[Migrate] \(summary)")
        return MigrationResult(migratedCount: migrated, backupURL: backupURL, legacyFound: legacy.count, summary: summary)
    }

    // MARK: - Helpers

    private static func fileModificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Parse a date from a legacy filename base like `transcript-2026-06-09-1530`.
    private static func parseLegacyDate(_ base: String) -> Date? {
        legacyStamp.date(from: base)
    }

    static let legacyStamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "'transcript-'yyyy-MM-dd-HHmm"; return f
    }()
    static let backupStamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
    }()
}

/// Serial, throttled title/tag backfill so we never hammer the on-device model with hundreds of
/// sessions at once. Processes one folder at a time with a small pause between.
public actor TitleBackfill {
    public static let shared = TitleBackfill()
    private var queued = Set<String>()
    private var pending: [URL] = []
    private var running = false

    public func enqueue(_ dirs: [URL]) {
        for d in dirs where !queued.contains(d.path) {
            queued.insert(d.path)
            pending.append(d)
        }
        guard !running, !pending.isEmpty else { return }
        running = true
        Task { await drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let dir = pending.removeFirst()
            queued.remove(dir.path)
            // D1: mint a stable session id for pre-existing folders on the same serial, throttled
            // queue as titling — so old sessions acquire one lazily without a migration pass, and
            // without ever racing the title write.
            SessionStore.ensureSessionID(dir: dir)
            await SessionStore.ensureTitle(dir: dir)
            try? await Task.sleep(nanoseconds: 300_000_000)   // be gentle on the model
        }
        running = false
    }
}
