import Foundation

/// Where a session's transcript lives — and what it is called.
///
/// It used to be a fixed `transcript.md`: unambiguous in code, and meaningless the moment the file
/// left its folder (a Downloads directory holding `transcript.md`, `transcript 2.md`,
/// `transcript 3.md` tells you nothing). A transcript is now named after the session that produced
/// it — `2026-09-01 14-32 Standup with Priya.md`. Date first so a pile of them sorts
/// chronologically; the title after it so you can read what it is. Until the on-device title lands
/// the body is the word `Transcript`, and `ensureTitle` renames the file when it does.
///
/// **Nothing on disk is migrated.** `transcript.md` is still read wherever it is found, still
/// written when it is the name a folder already uses, and still the name created when a caller has
/// no meta to derive one from — so a library recorded before this change keeps working untouched,
/// and only a session whose title is generated (or regenerated) is ever renamed.
public enum SessionPaths {

    /// The historical fixed name. Still valid; still the fallback.
    public static let legacyTranscriptName = "transcript.md"

    // MARK: - Resolving

    /// The transcript actually present in `dir`, whatever it is called — nil if there is none.
    ///
    /// `transcript.md` is checked first, so every pre-existing session resolves in one `stat` and
    /// behaves exactly as it did. Only a folder without one is enumerated.
    public static func existingTranscript(in dir: URL) -> URL? {
        let fm = FileManager.default
        let legacy = dir.appendingPathComponent(legacyTranscriptName)
        if fm.fileExists(atPath: legacy.path) { return legacy }
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        let candidates = names.filter {
            !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".md") && !$0.hasSuffix(".redacted.md")
        }.sorted()
        return candidates.first.map { dir.appendingPathComponent($0) }
    }

    /// The transcript to READ in `dir`. Falls back to the legacy name when the folder has none, so a
    /// missing transcript reads as a missing `transcript.md` exactly like it always did.
    public static func transcriptURL(in dir: URL) -> URL {
        existingTranscript(in: dir) ?? dir.appendingPathComponent(legacyTranscriptName)
    }

    /// The transcript to WRITE in `dir` for `meta`: the file the folder already uses if there is
    /// one — so the live save, the final save and the diarization re-render all land on a single
    /// file — else a fresh session-derived name.
    public static func transcriptURL(in dir: URL, for meta: SessionMeta) -> URL {
        existingTranscript(in: dir) ?? dir.appendingPathComponent(transcriptFileName(for: meta))
    }

    /// `dir` is a session folder (it holds a transcript).
    public static func isSessionFolder(_ dir: URL) -> Bool { existingTranscript(in: dir) != nil }

    // MARK: - Naming

    /// `2026-09-01 14-32 Standup with Priya.md`, or `2026-09-01 14-32 Transcript.md` when the
    /// session has no title yet.
    public static func transcriptFileName(for meta: SessionMeta) -> String {
        let title = safeFileComponent(TitleGenerator.sanitizeTitle(meta.title ?? ""))
        let body = title.isEmpty ? "Transcript" : String(title.prefix(120))
        return "\(fileStamp.string(from: meta.date)) \(body).md"
    }

    /// Strip the characters a file name cannot carry. Returns "" for an empty/blank input — callers
    /// that need a placeholder use `exportFilename`.
    public static func safeFileComponent(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        // Substituting a space per stripped character would leave "Q3/Q4: plans?" as "Q3 Q4  plans",
        // so runs collapse to one space.
        var cleaned = s.components(separatedBy: bad).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }   // never author a hidden file
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A file name for an export or a share, with the same `Transcript` placeholder and 120-char cap
    /// the share sheet has always used.
    public static func exportFilename(_ s: String) -> String {
        let cleaned = safeFileComponent(s)
        return cleaned.isEmpty ? "Transcript" : String(cleaned.prefix(120))
    }

    // MARK: - Renaming

    /// Rename the transcript in `dir` to match `meta` — how a session picks up its on-device title.
    ///
    /// A no-op when there is no transcript, when the name is already right, or when something else
    /// occupies the destination (a collision is left alone rather than resolved: the file staying
    /// where it is costs nothing, and every reader resolves it either way). Returns the new URL only
    /// when a rename actually happened.
    @discardableResult
    public static func renameTranscript(in dir: URL, toMatch meta: SessionMeta) -> URL? {
        guard let current = existingTranscript(in: dir) else { return nil }
        let desired = transcriptFileName(for: meta)
        guard current.lastPathComponent != desired else { return nil }
        let dest = dir.appendingPathComponent(desired)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return nil }
        do {
            try FileManager.default.moveItem(at: current, to: dest)
            return dest
        } catch {
            NSLog("[Session] transcript rename failed (\(current.lastPathComponent) → \(desired)): \(error)")
            return nil
        }
    }

    static let fileStamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"; return f
    }()
}
