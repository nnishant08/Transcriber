import Foundation

// MARK: - Portability seams
//
// SaidKit is compiled for BOTH macOS and iOS. The two platforms disagree about exactly three
// things that the core cares about: where sessions live, what "delete" means, and what the app
// calls itself in a bundle manifest. Each is a seam with a real implementation on both sides —
// never an `#if` that guards away functionality (see CLAUDE.md, "Portability seams").
//
// The macOS values are the DEFAULTS, unchanged from before the split, so the Mac app sets nothing
// at launch except the one thing it must: the Trash implementation (C2).

// MARK: C1 — Session root

/// Where session folders live. Injectable so the iOS app can point at its container and so
/// self-tests can point at a temp directory.
///
/// **Decision (see CLAUDE.md):** the macOS root stays `~/Desktop/Transcripts` and is deliberately
/// NOT renamed to `~/Desktop/Said`. Renaming buys a cosmetic win and costs a migration of every
/// existing session folder plus every stored path. If it is ever wanted it is a separate, opt-in
/// migration on the `--selftest-migrate` pattern.
public enum SessionLocation {

    /// The default root for this platform.
    ///
    /// macOS: `~/Desktop/Transcripts` — byte-for-byte the path the app has always used.
    /// iOS:   the app container's Documents directory (visible in Files when the app opts in).
    public static func platformDefaultRoot() -> URL {
        #if os(macOS)
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcripts", isDirectory: true)
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    /// The resolver every call site goes through. Replace it to relocate the store.
    public static var rootProvider: @Sendable () -> URL = { SessionLocation.platformDefaultRoot() }

    /// The current session root.
    public static var root: URL { rootProvider() }

    /// Restore the platform default (used by self-tests that temporarily inject a temp root).
    public static func resetRootToPlatformDefault() {
        rootProvider = { SessionLocation.platformDefaultRoot() }
    }
}

// MARK: C2 — Deleting a session

public enum SessionTrashError: Error, CustomStringConvertible {
    /// macOS reached the delete path with no Trash implementation injected. We refuse rather than
    /// fall back to `removeItem`: "never a hard delete on macOS" is a user-facing promise, and a
    /// silent hard delete is exactly the failure that promise exists to prevent.
    case noTrashImplementation

    public var description: String {
        switch self {
        case .noTrashImplementation:
            return "No Trash implementation was injected. Refusing to delete rather than hard-delete on macOS."
        }
    }
}

/// How a session (or one of its files) is destroyed.
///
/// macOS moves to the user's Trash — `Said` injects that at launch. iOS has no Trash, so the
/// SaidKit default removes the item directly. The macOS *default* (i.e. nothing injected) throws,
/// so a missing injection is a loud failure instead of a silent hard delete.
public enum SessionTrash {

    /// The platform default, used until something injects.
    public static func platformDefaultTrash(_ url: URL) throws {
        #if os(macOS)
        throw SessionTrashError.noTrashImplementation
        #else
        try FileManager.default.removeItem(at: url)
        #endif
    }

    /// The destructive operation every SaidKit delete path goes through.
    public static var handler: @Sendable (URL) throws -> Void = { try SessionTrash.platformDefaultTrash($0) }

    /// True once something has replaced the platform default. `--selftest-portability` asserts that
    /// the un-injected macOS path refuses.
    public private(set) static var isInjected = false

    /// Install the platform's real delete. On macOS `Said` passes `FileManager.trashItem` — NOT
    /// `NSWorkspace.recycle`, which routes through Finder via an Apple Event and stalls without
    /// Automation permission (see the note in `LibraryModel.delete`).
    public static func inject(_ handler: @escaping @Sendable (URL) throws -> Void) {
        self.handler = handler
        isInjected = true
    }

    /// Restore the platform default (self-tests only).
    public static func resetToPlatformDefault() {
        handler = { try SessionTrash.platformDefaultTrash($0) }
        isInjected = false
    }

    public static func trash(_ url: URL) throws { try handler(url) }
}

// MARK: - App identity (for bundle manifests / export headers)

/// The name and version SaidKit stamps into things it produces (`.said` manifests, export headers).
/// Read from the host bundle when there is one, with a literal fallback so the CLI self-test binary
/// — which has no bundle — still produces a well-formed manifest.
public enum SaidAppInfo {
    public static let name = "Said"

    public static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    public static var platformName: String {
        #if os(macOS)
        return "macOS"
        #else
        return "iOS"
        #endif
    }

    /// e.g. `Said 1.0 (macOS)` — the `producedBy` field of a `.said` manifest.
    public static var producedBy: String { "\(name) \(version) (\(platformName))" }
}
