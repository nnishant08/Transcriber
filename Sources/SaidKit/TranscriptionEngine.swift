import Foundation

/// The live transcription state surfaced to the UI: confirmed (locked, timestamped) segments
/// plus the trailing in-flight hypothesis. `text` is the full concatenation used for saving /
/// summarizing (kept identical to the prior behavior).
public struct LiveTranscript: Sendable {
    public var confirmed: [TranscriptSegment]
    public var hypothesis: String
    public var text: String { TranscriptText.clean(confirmed.map { $0.text }.joined() + hypothesis) }
}

/// The façade every caller in the app talks to — `AppModel`, `Importer`, every self-test.
///
/// **Phase 3 changed what is underneath it, not what it looks like.** The engine seam
/// (`TranscriptionProvider`) was introduced BELOW this type rather than in place of it, deliberately:
/// the callers above are the part of the tree with the least test coverage, and swapping the ASR
/// engine is already the largest regression risk in the phase. So `TranscriptionEngine` still owns
/// the shared `SampleSink`, still exposes prepare / stream / final-pass, and now additionally knows
/// which provider is answering.
///
/// It holds BOTH providers but loads at most the one in use — see `prepare(preference:…)`, which
/// unloads the loser so two 600 MB models never sit resident for a session that needs one.
public final class TranscriptionEngine: @unchecked Sendable {
    public init() {}

    public let sink = SampleSink()

    private let whisper = WhisperProvider()
    private let parakeet = ParakeetProvider()
    private let lock = NSLock()
    private var active: TranscriptionEngineID = .whisper
    private var decision: EngineRouter.Decision?

    /// Which engine is loaded, and why it was chosen. `AppModel` stamps both into `SessionMeta` so a
    /// user can always tell what produced a transcript, and shows `reason` in the status bar when
    /// the router had to fall back.
    public var activeEngine: TranscriptionEngineID {
        lock.lock(); defer { lock.unlock() }
        return active
    }
    public var activeDecision: EngineRouter.Decision? {
        lock.lock(); defer { lock.unlock() }
        return decision
    }
    public var activeModelName: String? { provider(active).loadedModelName }

    private func provider(_ id: TranscriptionEngineID) -> any TranscriptionProvider {
        id == .parakeet ? parakeet : whisper
    }

    public var isReady: Bool { provider(activeEngine).loadedModelName != nil }
    public var sampleCount: Int { sink.count }

    /// True when the given engine's models are already on disk. Feeds `EngineRouter`, so routing
    /// never sends a session to an engine that would have to download mid-record — which with
    /// "Never download models" on would fail outright.
    public static func isInstalled(_ id: TranscriptionEngineID, whisperVariant: String) -> Bool {
        let fm = FileManager.default
        switch id {
        case .whisper:
            return fm.fileExists(atPath: ModelStorage.whisperRoot
                .appendingPathComponent(whisperVariant, isDirectory: true).path)
        case .parakeet:
            return !ModelStorage.inventory().filter { $0.kind == .parakeet }.isEmpty
        }
    }

    // MARK: Preparation

    /// Route, then load. The primary entry point for a recording session.
    ///
    /// - Parameter language: the resolved language, or `nil` for an "Auto" session whose detection
    ///   has not run yet. A `nil` routes to Whisper (see `EngineRouter.choose` for why guessing
    ///   toward Whisper is the only safe direction), which is also the engine that can then DO the
    ///   detection — so the Auto flow falls out of the routing rule rather than needing a special case.
    /// - Returns: the decision, for `SessionMeta` and the status line.
    @discardableResult
    public func prepare(preference: EnginePreference,
                        language: String?,
                        whisperVariant: String,
                        progress: @escaping @Sendable (String, Double?) -> Void) async throws -> EngineRouter.Decision {
        let choice = EngineRouter.choose(
            preference: preference,
            language: language,
            parakeetInstalled: Self.isInstalled(.parakeet, whisperVariant: whisperVariant),
            whisperInstalled: Self.isInstalled(.whisper, whisperVariant: whisperVariant)
        )
        let variant = choice.engine == .parakeet ? ParakeetProvider.Variant.v3.rawValue : whisperVariant
        try await provider(choice.engine).prepare(variant: variant, progress: progress)

        lock.lock(); let previous = active; active = choice.engine; decision = choice; lock.unlock()
        if previous != choice.engine { await provider(previous).unload() }
        return choice
    }

    /// Prepare a SPECIFIC Whisper model, bypassing the router.
    ///
    /// Kept exactly as it was so the import path and every pre-Phase-3 self-test compile and behave
    /// unchanged — `--selftest`, `--selftest-stream`, `--selftest-detect`, `--selftest-multilingual`
    /// and `--selftest-vocab` all pin a Whisper variant on purpose, and rewriting them would destroy
    /// their value as the regression proof for this refactor.
    public func prepare(model: String, progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        try await whisper.prepare(variant: model, progress: progress)
        lock.lock(); active = .whisper
        decision = EngineRouter.Decision(engine: .whisper, reason: "Whisper (\(model))")
        lock.unlock()
    }

    /// Prepare a specific Parakeet variant, bypassing the router (`--selftest-parakeet`).
    public func prepareParakeet(variant: ParakeetProvider.Variant = .v3,
                                progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        try await parakeet.prepare(variant: variant.rawValue, progress: progress)
        lock.lock(); active = .parakeet
        decision = EngineRouter.Decision(engine: .parakeet, reason: "Parakeet (\(variant.rawValue))")
        lock.unlock()
    }

    /// Whether custom vocabulary actually reaches the decoder on the ACTIVE engine right now.
    public var vocabularyBiasIsEffective: Bool { provider(activeEngine).supportsVocabularyBias }

    // MARK: Vocabulary

    /// Whisper's `promptTokens` construction, retained on the façade because `--selftest-vocab`
    /// asserts it directly — including the invariant that an empty term list yields **nil**, never
    /// `[]`. Parakeet does not use prompt tokens; it takes `VocabularyBias` and runs a CTC spotter.
    public func promptTokens(for terms: [String]) -> [Int]? {
        whisper.promptTokensForSelfTest(terms: terms)
    }

    // MARK: Streaming

    /// Build a streaming transcriber on the active provider, bound to the shared sink.
    ///
    /// `async` now (it was synchronous) because Parakeet's sliding-window manager is an actor that
    /// loads, configures biasing and starts before it can accept audio. Both of `AppModel`'s call
    /// sites were already inside async contexts.
    public func makeStreamer(language: String?, bias: VocabularyBias? = nil,
                             onUpdate: @escaping @Sendable (LiveTranscript) -> Void) async -> (any TranscriptionStream)? {
        await provider(activeEngine).makeStream(sink: sink, language: language, bias: bias, onUpdate: onUpdate)
    }

    // MARK: Language detection

    /// One-shot language detection over a lead-in sample.
    ///
    /// Always answered by **Whisper**, whichever engine is active, because Parakeet has no
    /// language-ID head at all (verified at the pinned tag). Detection therefore requires a loaded
    /// Whisper model — which the Auto flow guarantees, since a `nil` language routes to Whisper in
    /// the first place.
    public func detectLanguage(samples: [Float]) async throws -> (language: String, probs: [String: Float]) {
        try await whisper.detectLanguageDetailed(samples: samples)
    }

    // MARK: Transcription

    /// One-shot full-quality transcription of an audio FILE, returning plain joined text.
    public func transcribeFile(_ path: String, language: String?, bias: VocabularyBias? = nil) async throws -> String {
        let segs = try await provider(activeEngine).transcribeFile(path: path, language: language, bias: bias)
        return TranscriptText.clean(segs.map { $0.text }.joined(separator: " "))
    }

    /// One full-quality, non-streaming pass over the entire recorded audio (the shared sink).
    public func finalPassSegments(language: String?, bias: VocabularyBias? = nil) async throws -> [TranscriptSegment] {
        try await transcribeSamples(sink.snapshot(), language: language, bias: bias)
    }

    /// Full-quality transcription of an explicit sample buffer → timed segments. Shared by the live
    /// `finalPass` and the file/video import path.
    public func transcribeSamples(_ samples: [Float], language: String?,
                                  bias: VocabularyBias? = nil) async throws -> [TranscriptSegment] {
        try await provider(activeEngine).transcribe(samples: samples, language: language, bias: bias)
    }

    /// One full-quality, non-streaming pass returning plain joined text (used by self-tests).
    public func finalPass(language: String?, bias: VocabularyBias? = nil) async throws -> String {
        let segments = try await finalPassSegments(language: language, bias: bias)
        return TranscriptText.clean(segments.map { $0.text }.joined(separator: " "))
    }
}

/// Small text tidy-up shared by streaming + final passes.
public enum TranscriptText {
    public static func clean(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "  ", with: " ")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
