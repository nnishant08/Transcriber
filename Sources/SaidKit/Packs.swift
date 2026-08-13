import Foundation

/// Sensible defaults a pack can set when enabled (purely additive; the user can still override).
struct PackDefaults: Codable, Sendable, Hashable {
    var defaultSummaryStyle: String?     // a SummaryStyle raw value, applied as the Studio default
    var featuredTemplateIds: [String]?   // surfaced prominently in the Studio
}

/// An installable vertical bundle (Feature B): curated custom vocabulary + a curated set of
/// Feature-A template ids + defaults. Loaded from `Resources/Packs/*.json` (shipped with the app via
/// SPM resources → `Bundle.module`). Backend/commerce is NOT built — availability routes through the
/// `Entitlements` seam, which grants everything in this build.
public struct Pack: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var description: String
    public var vocabulary: [String]
    public var templateIds: [String]
    var defaults: PackDefaults?
}

/// Loads bundled packs, tracks which are enabled (persisted), and merges their vocabulary into the
/// existing custom-vocabulary bias path. Thread-safe-ish: loading happens once at init; reads are
/// value copies. The empty ⇒ no-op contract is preserved (no pack + no user vocab ⇒ [] ⇒ nil tokens).
public final class PackManager: @unchecked Sendable {
    public static let shared = PackManager()

    private(set) var packs: [Pack] = []
    private let enabledKey = "enabledPackIDs"

    private init() { packs = Self.loadBundledPacks() }

    /// Re-scan the bundle (used by self-tests with an injected directory).
    @discardableResult
    public func reload(from directory: URL? = nil) -> [Pack] {
        packs = Self.loadBundledPacks(directory: directory)
        return packs
    }

    func pack(id: String) -> Pack? { packs.first { $0.id == id } }

    /// Packs the current entitlement grants (all of them in this build).
    public var availablePacks: [Pack] { packs.filter { Entitlements.isEntitled(.verticalPack($0.id)) } }

    // MARK: Enabled set (persisted)

    public var enabledPackIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: enabledKey) }
    }
    func isEnabled(_ id: String) -> Bool { enabledPackIDs.contains(id) }
    func setEnabled(_ id: String, _ on: Bool) {
        guard Entitlements.isEntitled(.verticalPack(id)) else { return }
        var set = enabledPackIDs
        if on { set.insert(id) } else { set.remove(id) }
        enabledPackIDs = set
    }

    var enabledPacks: [Pack] { availablePacks.filter { enabledPackIDs.contains($0.id) } }

    // MARK: Vocabulary merge (preserves empty ⇒ no-op)

    /// Union of the user's vocabulary and every enabled pack's vocabulary, deduped case-insensitively
    /// while preserving first-seen order (user terms first). Empty input + no enabled packs ⇒ [].
    public func mergedVocabulary(userVocab: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ term: String) {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let key = t.lowercased()
            if seen.insert(key).inserted { out.append(t) }
        }
        userVocab.forEach(add)
        for pack in enabledPacks { pack.vocabulary.forEach(add) }
        return out
    }

    // MARK: Template exposure

    /// Template ids surfaced prominently by enabled packs, validated against the known registry
    /// (a pack referencing an unknown template id is ignored gracefully).
    func exposedTemplateIDs() -> [String] {
        let known = Set(GenerationStudio.builtins.map { $0.id })
        var seen = Set<String>(), out: [String] = []
        for pack in enabledPacks {
            for id in (pack.defaults?.featuredTemplateIds ?? pack.templateIds) where known.contains(id) {
                if seen.insert(id).inserted { out.append(id) }
            }
        }
        return out
    }

    /// The default summary style an enabled pack requests, if any (first enabled pack wins).
    func preferredSummaryStyle() -> SummaryStyle? {
        for pack in enabledPacks {
            if let raw = pack.defaults?.defaultSummaryStyle, let s = SummaryStyle(rawValue: raw) { return s }
        }
        return nil
    }

    // MARK: Loading

    private static func loadBundledPacks(directory: URL? = nil) -> [Pack] {
        let urls = packJSONURLs(directory: directory)
        var out: [Pack] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let data = try Data(contentsOf: url)
                let pack = try JSONDecoder().decode(Pack.self, from: data)
                guard !pack.id.isEmpty, !pack.name.isEmpty else {
                    NSLog("[Packs] skipped \(url.lastPathComponent): missing id/name"); continue
                }
                out.append(pack)
            } catch {
                NSLog("[Packs] skipped \(url.lastPathComponent): \(error)")   // malformed → skip, others load
            }
        }
        return out
    }

    /// Locate the bundled pack JSON files. Prefers an explicit directory (self-tests), else the
    /// `Packs/` resource subdirectory shipped via SPM resources (`Bundle.module`).
    private static func packJSONURLs(directory: URL?) -> [URL] {
        if let directory {
            return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "json" } ?? []
        }
        #if SWIFT_PACKAGE
        if let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Packs"), !urls.isEmpty {
            return urls
        }
        // Fallback: SPM sometimes flattens single-dir resources to the bundle root.
        if let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) {
            return urls.filter { $0.lastPathComponent.hasPrefix("pack-") }
        }
        #endif
        return []
    }
}
