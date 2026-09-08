import Foundation

// MARK: - The offline promise, made enforceable

public enum ModelGateError: LocalizedError {
    /// A model acquisition was refused because the user turned downloads off.
    case downloadsDisabled(what: String)

    public var errorDescription: String? {
        switch self {
        case .downloadsDisabled(let what):
            return "\(what) isn't downloaded, and \"Never download models\" is on. "
                 + "Turn it off in Settings ▸ Privacy to fetch it, or pick a model you already have."
        }
    }
}

/// **The single place any model may be fetched from the network.**
///
/// Said's central claim is that nothing leaves the device. Until now that was true because the code
/// was written that way, and a reader could verify it by auditing every call site. This turns it
/// into something the app *enforces*: with "Never download models" on, every acquisition path
/// throws `ModelGateError.downloadsDisabled` **before** any network call is constructed, and the UI
/// says which model is missing rather than failing obscurely.
///
/// **Why this is not `ModelHub.offlineMode`.** FluidAudio grew exactly that flag — at v0.15.5, three
/// tags past the pin, in the same change that deleted `DownloadUtils` (see `Package.swift` for why
/// the pin is held). But even taking the bump, that flag would only cover FluidAudio. Said ships two
/// ASR engines, and **WhisperKit has no offline flag at any version**, so a library-level switch
/// leaves half the promise unenforced. A gate one level up covers Whisper, Parakeet, the CTC
/// vocabulary spotter and the diarizer with one rule and one test.
///
/// The gate governs *fetching*, never *loading*: an already-downloaded model loads from disk exactly
/// as before, which is what makes "airplane mode with models present" a working configuration
/// rather than a degraded one.
public enum ModelGate {

    /// Persisted in `UserDefaults`, off by default — turning it on must be the user's decision, and
    /// defaulting it on would brick a fresh install that has no models yet.
    public static var neverDownloadModels: Bool {
        get { UserDefaults.standard.bool(forKey: "neverDownloadModels") }
        set { UserDefaults.standard.set(newValue, forKey: "neverDownloadModels") }
    }

    /// Call immediately before any code path that could reach the network for a model.
    /// - Parameter what: user-facing name of the thing being fetched, e.g. `"The Parakeet model"`.
    public static func requireDownloadAllowed(_ what: String) throws {
        guard neverDownloadModels else { return }
        NSLog("[ModelGate] refused a download of \(what) — \"Never download models\" is on")
        throw ModelGateError.downloadsDisabled(what: what)
    }

    /// True when a fetch would be refused. Lets the UI grey a control out and explain *before* the
    /// user commits to a recording, instead of failing at the moment they press record.
    public static var downloadsBlocked: Bool { neverDownloadModels }
}

// MARK: - What is actually on disk (§10.2a)

/// One model family found on disk.
public struct InstalledModel: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        case whisper
        case parakeet
        case vocabularySpotter   // the separate CTC model Parakeet's vocabulary boosting needs
        case diarizer
        case other

        public var displayName: String {
            switch self {
            case .whisper:           return "Whisper"
            case .parakeet:          return "Parakeet"
            case .vocabularySpotter: return "Custom vocabulary"
            case .diarizer:          return "Speaker identification"
            case .other:             return "Other"
            }
        }
    }

    public let id: String            // the directory path — stable, and what `delete` acts on
    public let kind: Kind
    public let name: String          // e.g. "openai_whisper-base.en", "parakeet-tdt-0.6b-v3-coreml"
    public let url: URL
    public let sizeBytes: Int64

    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Inventory + deletion for the models Said has downloaded.
///
/// **Why this exists at all.** Phase 3 leaves two ASR engines resident where there was one, plus the
/// diarizer, plus the CTC spotter that vocabulary boosting needs, plus optionally an embedding
/// model. None of it was ever visible to the user. "Privacy-first" is a poor consolation for an
/// unexplained multi-gigabyte home directory, and a user who never records in Hindi should be able
/// to reclaim the Whisper model they no longer need.
///
/// **It discovers rather than predicts.** The roots below are source-verified from the two
/// dependencies at their pinned tags, but what is *inside* them is enumerated, not guessed — so a
/// model variant Said has never heard of still shows up and can still be deleted. A storage panel
/// that only reports the files it expected is worse than none.
public enum ModelStorage {

    // MARK: Roots (source-verified at the pinned tags)

    /// WhisperKit's cache. `WhisperKit.download(variant:downloadBase:)` defaults `downloadBase` to
    /// nil, and `HubApiWrapper` then resolves it to `Documents/huggingface`
    /// (argmax-oss-swift 1.1.0, `Sources/ArgmaxCore/HubWrapper.swift`).
    public static var whisperRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    /// FluidAudio's cache — Parakeet, the CTC spotter and the diarizer all live under here.
    /// `MLModelConfigurationUtils.defaultModelsDirectory` (FluidAudio 0.15.2) builds exactly this.
    public static var fluidRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Where the optional sentence-embedding model for semantic search is kept (Wave 6). Said's own
    /// directory — it is not a dependency's asset, so nothing else manages its lifetime.
    public static var embeddingRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Said", isDirectory: true)
            .appendingPathComponent("Embedding", isDirectory: true)
    }

    // MARK: Inventory

    /// Everything Said has downloaded, largest first.
    public static func inventory() -> [InstalledModel] {
        var out: [InstalledModel] = []
        out += children(of: whisperRoot).map { url in
            model(at: url, kind: .whisper)
        }
        // FluidAudio nests one directory per HuggingFace repo folder name; a couple of repos carry a
        // sub-path ("…/ANE"), so classify on the leading component and report whatever is there.
        out += children(of: fluidRoot).map { url in
            model(at: url, kind: classifyFluid(url.lastPathComponent))
        }
        if FileManager.default.fileExists(atPath: embeddingRoot.path) {
            out += children(of: embeddingRoot).map { model(at: $0, kind: .other) }
        }
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Total bytes across every installed model.
    public static func totalBytes(_ models: [InstalledModel]? = nil) -> Int64 {
        (models ?? inventory()).reduce(0) { $0 + $1.sizeBytes }
    }

    private static func model(at url: URL, kind: InstalledModel.Kind) -> InstalledModel {
        InstalledModel(id: url.path, kind: kind, name: url.lastPathComponent,
                       url: url, sizeBytes: directorySize(url))
    }

    private static func classifyFluid(_ folder: String) -> InstalledModel.Kind {
        let f = folder.lowercased()
        if f.contains("diariz") || f.contains("sortformer") || f.contains("eend") { return .diarizer }
        if f.contains("ctc-110m") || f.contains("ctc110m") { return .vocabularySpotter }
        if f.contains("parakeet") || f.contains("nemotron") { return .parakeet }
        return .other
    }

    private static func children(of root: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    /// Recursive on-disk size. Uses allocated size where the filesystem reports it, because that is
    /// the number that matches what the user sees in Finder and in "About This Mac ▸ Storage".
    public static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                    options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Deletion

    /// Permanently remove one downloaded model.
    ///
    /// Deleting is real and immediate — the whole point is reclaiming the space. The *warning* about
    /// deleting something currently required is the caller's job (`isRequired(_:...)` below), because
    /// only the caller knows the live settings. This function does not second-guess a decision the
    /// user has already confirmed.
    public static func delete(_ model: InstalledModel) throws {
        try FileManager.default.removeItem(at: model.url)
        NSLog("[ModelStorage] deleted \(model.name) (\(model.displaySize))")
    }

    /// Whether removing `model` would break the CURRENT settings — i.e. the next recording would
    /// need it and, with downloads possibly disabled, might not be able to get it back.
    public static func isRequired(_ model: InstalledModel,
                                  enginePreference: EnginePreference,
                                  whisperVariant: String,
                                  diarizationEnabled: Bool,
                                  vocabularyBiasActive: Bool) -> Bool {
        switch model.kind {
        case .whisper:
            // The selected Whisper model matters whenever Whisper can run at all — which under
            // `.automatic` includes "a language Parakeet doesn't cover", i.e. always possible.
            guard model.name == whisperVariant else { return false }
            return enginePreference != .parakeet
        case .parakeet:
            return enginePreference != .whisper
        case .vocabularySpotter:
            return vocabularyBiasActive && enginePreference != .whisper
        case .diarizer:
            return diarizationEnabled
        case .other:
            return false
        }
    }
}
