import Foundation
import SaidKit

/// Wires SaidKit's portability seams to their iOS implementations. Called once, at launch, before
/// anything can touch the store.
///
/// Phase 1 designed these as seams precisely so this file could be short: the core already knows how
/// to do the work, it just needs telling where sessions live and what "delete" means here.
enum AppEnvironment {

    static func configure() {
        // C1 — sessions live in the app container's Documents directory, which is also what makes
        // them visible in the Files app (UIFileSharingEnabled). The macOS default is unaffected.
        SessionLocation.rootProvider = { documentsRoot }

        // C2 — iOS has no Trash, so deletion removes directly. The Mac's "never a hard delete"
        // promise is macOS-specific: there, SaidKit REFUSES unless the app injects trashItem.
        SessionTrash.inject { url in
            try FileManager.default.removeItem(at: url)
        }

        prepareSupportDirectory()
    }

    /// The session store root.
    static var documentsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Where the transcription model and the search index live.
    ///
    /// Application Support, NOT Documents: these are re-downloadable derived data, and putting them
    /// in Documents would expose them in the Files app alongside the user's actual recordings.
    static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Said", isDirectory: true)
    }

    /// Create the support directory and exclude it from iCloud backup.
    ///
    /// A re-downloadable model must never bloat a user's backup. The exclusion is set on the
    /// directory AFTER creating it — setting it on a path that does not exist yet silently does
    /// nothing, which is the classic way this ends up not working.
    private static func prepareSupportDirectory() {
        var dir = supportRoot
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
        } catch {
            NSLog("[Env] support directory setup failed: \(error)")
        }
    }

    /// Read back the flag, so a test can prove the exclusion actually took.
    static func isSupportExcludedFromBackup() -> Bool {
        (try? supportRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }
}
