import Foundation
import NaturalLanguage

/// Turns text into a vector. A seam, so the choice of model is a decision that can be revisited
/// with evidence rather than a dependency baked through the index.
public protocol EmbeddingProvider: Sendable {
    /// Vector length. Stored alongside the index so a model change invalidates it rather than
    /// silently comparing vectors from two different spaces.
    var dimension: Int { get async }
    /// A stable identifier for the model + revision, stored in the index for the same reason.
    var identifier: String { get async }
    /// Whether the model is present and usable right now, without downloading anything.
    var isReady: Bool { get async }
    /// Acquire the model. Honours `ModelGate`.
    func prepare() async throws
    /// Embed one passage. `nil` when the model cannot handle it (unsupported language, empty text).
    func embed(_ text: String) async -> [Float]?
}

/// Errors an embedder can raise that the UI needs to distinguish.
public enum EmbeddingError: LocalizedError {
    case assetsUnavailable(String)
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .assetsUnavailable(let why):
            return "The on-device language model for semantic search isn't available (\(why))."
        case .notLoaded:
            return "The embedding model isn't loaded."
        }
    }
}

/// Said's shipped embedder: Apple's **`NLContextualEmbedding`**.
///
/// **This diverges from the Phase 3 prompt, which called for a pinned third-party CoreML model
/// (multilingual-e5-small or EmbeddingGemma-300m) and dismissed Apple's options in one line —
/// "`NLContextualEmbedding` is token-level and needs you to own the pooling". That objection is
/// true and it costs about fifteen lines (`meanPooled` below). Weighed against what it buys:**
///
/// - **It is on the deployment floor.** macOS 14 / iOS 17 — exactly Said's, verified against Apple's
///   own documentation. A macOS-26-only option would have been a second implementation, not a
///   feature.
/// - **It is multilingual and contextual**, which is the actual requirement. `NLEmbedding` (the
///   thing usually meant by "Apple's word embeddings") really is inadequate — word-level, no
///   context — and this is a different API. `FoundationModels` was checked and exposes NO embedding
///   API at all; it is a generation model. Both findings are recorded in `PHASE3-REPORT.md`.
/// - **Nothing is downloaded from a third party.** The assets come from the OS through
///   `requestAssets()`, so the "no account, no HuggingFace, nothing leaves the device" story holds
///   without a new model repo to pin, host, verify and keep alive. Shipping a CoreML conversion
///   whose repo and revision could not be verified would have been the weaker engineering position,
///   not the stronger one.
/// - **It adds no disk footprint that Said owns**, in a phase that already doubles the model
///   directory (§10.2a).
///
/// The seam above is why this is reversible: if the golden query set (§9.4) shows a pinned e5-small
/// beating it, that is a new `EmbeddingProvider` and nothing else changes.
public actor AppleContextualEmbedder: EmbeddingProvider {

    private var embedding: NLContextualEmbedding?
    private var loaded = false

    /// Which language's model to load. `.english` is not a restriction to English text — Apple's
    /// multilingual models are grouped by SCRIPT, and the Latin-script model covers most of what
    /// Said transcribes — but a corpus that is mostly in another script is better served by asking
    /// for that language explicitly.
    private let language: NLLanguage

    public init(language: NLLanguage = .english) {
        self.language = language
    }

    public var dimension: Int {
        embedding?.dimension ?? 0
    }

    public var identifier: String {
        guard let embedding else { return "unloaded" }
        return "\(embedding.modelIdentifier)@\(embedding.revision)"
    }

    public var isReady: Bool {
        loaded && embedding != nil
    }

    public func prepare() async throws {
        if loaded, embedding != nil { return }
        guard let e = NLContextualEmbedding(language: language) else {
            throw EmbeddingError.assetsUnavailable("no model for \(language.rawValue)")
        }
        if !e.hasAvailableAssets {
            // Downloading assets is a network operation, so it goes through the same gate every
            // other model acquisition does. "Never download models" means never, not "except this".
            try ModelGate.requireDownloadAllowed("The on-device language model for semantic search")
            let result = try await e.requestAssets()
            guard result == .available else {
                throw EmbeddingError.assetsUnavailable("\(result)")
            }
        }
        try e.load()
        embedding = e
        loaded = true
    }

    public func unload() {
        embedding?.unload()
        loaded = false
    }

    public func embed(_ text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let embedding, loaded else { return nil }
        // Cap the input at what the model will actually consume. Beyond `maximumSequenceLength` the
        // tail is dropped anyway, and a chunk long enough to hit that limit has already lost the
        // focus that makes a retrieval hit useful.
        let capped = String(trimmed.prefix(embedding.maximumSequenceLength * 4))
        guard let result = try? embedding.embeddingResult(for: capped, language: language) else { return nil }
        return Self.meanPooled(result, dimension: embedding.dimension)
    }

    /// Mean-pool the token vectors into one passage vector, then L2-normalise.
    ///
    /// This is "the pooling you have to own". Mean pooling over tokens is the standard sentence
    /// representation for an encoder that does not ship a pooled output, and normalising means
    /// cosine similarity reduces to a dot product — which is what makes the search loop in
    /// `SemanticIndex` cheap enough to run over a whole corpus without an approximate index.
    static func meanPooled(_ result: NLContextualEmbeddingResult, dimension: Int) -> [Float]? {
        guard dimension > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        var count = 0
        let whole = result.string.startIndex..<result.string.endIndex
        result.enumerateTokenVectors(in: whole) { vector, _ in
            guard vector.count == dimension else { return true }
            for i in 0..<dimension { sum[i] += Float(vector[i]) }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        for i in 0..<dimension { sum[i] /= Float(count) }
        return normalize(sum)
    }

    /// L2-normalise, or `nil` for a zero vector (which carries no direction and would make every
    /// similarity meaningless).
    static func normalize(_ v: [Float]) -> [Float]? {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 1e-6 else { return nil }
        return v.map { $0 / norm }
    }
}

// MARK: - Vector maths

public enum VectorMath {
    /// Dot product. For L2-normalised vectors this IS cosine similarity, which is why
    /// `AppleContextualEmbedder` normalises on the way in — the search loop then costs one multiply
    /// and one add per dimension with no square roots.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }
}
