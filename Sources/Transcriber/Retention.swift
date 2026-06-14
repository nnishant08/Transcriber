import Foundation

/// Feature C1 — retention policy. Persisted in UserDefaults; disabled by default (with defaults, the
/// launch sweep is a no-op and nothing is ever deleted).
struct RetentionPolicy: Codable, Sendable, Equatable {
    var autoDeleteEnabled: Bool = false
    var maxAgeDays: Int = 30
    var deleteAudioOnly: Bool = false      // when true, the sweep removes only audio (keeps the transcript)

    static let `default` = RetentionPolicy()
}

struct RetentionResult: Sendable {
    var deletedSessions: Int = 0
    var deletedAudio: Int = 0
    var skippedLocked: Int = 0
}

/// Auto-delete + manual purge tools. Deletions go to the Trash (never a hard delete — consistent
/// with the Library's existing delete behavior). The destructive action is injectable so self-tests
/// run against a temp "trash" directory rather than the user's real Trash.
enum Retention {

    static let key = "retentionPolicy"

    static var policy: RetentionPolicy {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let p = try? JSONDecoder().decode(RetentionPolicy.self, from: data) else { return .default }
            return p
        }
        set { if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) } }
    }

    /// Move a URL to the Trash (synchronous, throwing). The default app behavior; overridden in tests.
    static func trashToSystem(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// The launch-time sweep (idempotent, off-main). Sessions older than `maxAgeDays` that are NOT
    /// `retentionLocked` are trashed (or, when `deleteAudioOnly`, only their audio is removed and
    /// session.json updated). A delete failure logs and continues — never crashes the sweep.
    /// `now` and `trash` are injectable for testing.
    @discardableResult
    static func sweep(root: URL = SessionStore.root,
                      policy: RetentionPolicy = Retention.policy,
                      now: Date = Date(),
                      trash: (URL) throws -> Void = Retention.trashToSystem) -> RetentionResult {
        var result = RetentionResult()
        guard policy.autoDeleteEnabled, policy.maxAgeDays > 0 else { return result }
        let cutoff = now.addingTimeInterval(-Double(policy.maxAgeDays) * 86_400)

        for dir in SessionStore.sessionDirectoryURLs(root: root) {
            let doc = DocumentBuilder.readSession(dir)
            let meta = doc?.meta ?? SessionStore.synthMeta(dir: dir)
            guard meta.date < cutoff else { continue }                 // recent → keep
            if meta.retentionLocked == true { result.skippedLocked += 1; continue }

            if policy.deleteAudioOnly {
                guard let audio = meta.audioFile else { continue }     // already audio-free → idempotent no-op
                let audioURL = dir.appendingPathComponent(audio)
                guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }
                do {
                    try trash(audioURL)
                    if var d = doc { d.meta.audioFile = nil; d.meta.durationSeconds = nil; DocumentBuilder.writeSessionJSON(d, to: dir) }
                    result.deletedAudio += 1
                    SessionStore.postSessionSaved(dir)
                } catch { NSLog("[Retention] audio delete failed for \(dir.lastPathComponent): \(error)") }
            } else {
                do {
                    try trash(dir)
                    SearchIndex.shared.remove(dir: dir)
                    result.deletedSessions += 1
                } catch { NSLog("[Retention] delete failed for \(dir.lastPathComponent): \(error)") }
            }
        }
        if result.deletedSessions + result.deletedAudio > 0 {
            NSLog("[Retention] swept \(result.deletedSessions) session(s), \(result.deletedAudio) audio file(s), \(result.skippedLocked) kept")
            SessionStore.postSessionSaved(root)
        }
        return result
    }

    // MARK: - Manual tools (Settings / Library)

    /// Delete every saved audio file (keeps transcripts). Respects nothing — explicit user action.
    @discardableResult
    static func deleteAllAudio(root: URL = SessionStore.root,
                               trash: (URL) throws -> Void = Retention.trashToSystem) -> Int {
        var n = 0
        for dir in SessionStore.sessionDirectoryURLs(root: root) {
            guard var doc = DocumentBuilder.readSession(dir), let audio = doc.meta.audioFile else { continue }
            let url = dir.appendingPathComponent(audio)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try trash(url)
                doc.meta.audioFile = nil; doc.meta.durationSeconds = nil
                DocumentBuilder.writeSessionJSON(doc, to: dir)
                n += 1; SessionStore.postSessionSaved(dir)
            } catch { NSLog("[Retention] manual audio delete failed: \(error)") }
        }
        return n
    }

    /// Trash transcripts older than `days` (skips retention-locked sessions). Explicit user action.
    @discardableResult
    static func deleteOlderThan(days: Int, root: URL = SessionStore.root, now: Date = Date(),
                                trash: (URL) throws -> Void = Retention.trashToSystem) -> Int {
        let cutoff = now.addingTimeInterval(-Double(max(0, days)) * 86_400)
        var n = 0
        for dir in SessionStore.sessionDirectoryURLs(root: root) {
            let meta = DocumentBuilder.readSession(dir)?.meta ?? SessionStore.synthMeta(dir: dir)
            guard meta.date < cutoff, meta.retentionLocked != true else { continue }
            do { try trash(dir); SearchIndex.shared.remove(dir: dir); n += 1 }
            catch { NSLog("[Retention] manual delete failed: \(error)") }
        }
        if n > 0 { SessionStore.postSessionSaved(root) }
        return n
    }
}
