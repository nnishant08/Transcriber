import Foundation

// MARK: - Vocabulary bias

/// The engine-neutral form of "bias recognition toward these terms".
///
/// Two engines implement it completely differently — Whisper conditions the decoder prefill through
/// `DecodingOptions.promptTokens`, Parakeet runs a CTC keyword spotter and rescores the TDT
/// hypothesis — so the shared layer must not speak either dialect. It carries the terms; each
/// provider translates.
///
/// **The initializer is failable on purpose, and that is the whole point of the type.** Said has
/// shipped one invariant about custom vocabulary since Prompt 2: an empty term list must be an
/// *exact* no-op, byte-identical to not passing a vocabulary at all — never `[]`, which for Whisper
/// prepends a bare `<|startofprev|>` and changes the prefill, and for Parakeet would stand up a CTC
/// spotter and a rescorer that can only introduce substitutions. Making "empty" unrepresentable
/// means no provider can get that wrong, rather than each provider having to remember.
public struct VocabularyBias: Sendable, Equatable {
    /// Non-empty, trimmed, de-duplicated (case-insensitively), order-preserving.
    public let terms: [String]

    /// Returns `nil` — never an empty bias — when nothing usable is left after trimming.
    public init?(terms: [String]) {
        var seen = Set<String>()
        var kept: [String] = []
        for raw in terms {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            kept.append(t)
        }
        guard !kept.isEmpty else { return nil }
        self.terms = kept
    }
}

// MARK: - Engine identity

/// Which ASR family produced (or will produce) a transcript. Stored in `SessionMeta.engine`, so a
/// user can always tell what wrote their words.
public enum TranscriptionEngineID: String, Sendable, CaseIterable, Codable {
    case whisper
    case parakeet

    public var displayName: String {
        switch self {
        case .whisper:  return "Whisper"
        case .parakeet: return "Parakeet"
        }
    }
}

/// The user's engine preference (Settings). `automatic` is the default and the only one that routes
/// by language; the other two are escape hatches that always win.
public enum EnginePreference: String, Sendable, CaseIterable, Codable {
    case automatic
    case parakeet
    case whisper

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .parakeet:  return "Always Parakeet"
        case .whisper:   return "Always Whisper"
        }
    }

    /// One honest line each, shown under the picker. Each names the cost, not just the benefit.
    public var explanation: String {
        switch self {
        case .automatic:
            return "Parakeet for the languages it covers, Whisper for the rest. The session records which one ran."
        case .parakeet:
            return "Fastest, and the only engine that produces word-level timings — but it cannot transcribe languages outside its set."
        case .whisper:
            return "Covers far more languages and is slower, with no word timings, so editing and speaker splits fall back to whole lines."
        }
    }
}

// MARK: - Parakeet's language coverage, as data

/// Which languages the Parakeet v3 model can be routed to.
///
/// **Source-verified, not guessed.** These are exactly the codes FluidAudio's own
/// `Language` enum (`Sources/FluidAudio/Shared/TokenLanguageFilter.swift`, v0.15.2) accepts as a
/// transcription hint — the set the decoder knows how to script-filter for. NVIDIA's model card for
/// `parakeet-tdt-0.6b-v3` advertises "25 European languages" while that enum enumerates 30 codes;
/// where the two disagree the enum is the one the code actually honours, so it is what Said routes
/// on. A language outside this set goes to Whisper — see `EngineRouter`.
///
/// Deliberately a `Set<String>` of ISO codes rather than a mirror of FluidAudio's enum: this table
/// has to be readable, assertable and comparable against `SessionMeta.language` without SaidKit's
/// routing logic taking a dependency on a vendor type that has moved between releases.
public enum ParakeetLanguages {

    /// Parakeet v3 (`FluidInference/parakeet-tdt-0.6b-v3-coreml`), multilingual — 25 languages.
    ///
    /// FluidAudio's `Language` enum lists **28** codes, three more than the model card's 25: `be`
    /// (Belarusian), `bs` (Bosnian) and `sr` (Serbian). Those three are excluded here, and the
    /// direction of that choice is the point. The enum is a SCRIPT FILTER — it says which alphabets
    /// the decoder knows how to constrain itself to, which is a strict superset of which languages
    /// it was trained to transcribe. Routing a Belarusian recording to Parakeet on the strength of
    /// "the Cyrillic filter accepts it" is exactly the failure this router exists to prevent: the
    /// output would be fluent and wrong. They go to Whisper, which costs speed and nothing else.
    public static let v3: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "ro", "nl", "da", "sv", "fi", "hu",
        "et", "lv", "lt", "mt", "pl", "cs", "sk", "sl", "hr",
        "ru", "uk", "bg", "el",
    ]

    /// Parakeet v2 (`FluidInference/parakeet-tdt-0.6b-v2-coreml`), English only.
    public static let v2: Set<String> = ["en"]

    /// True when `code` is one Parakeet v3 can be asked to transcribe. `nil` (language not yet
    /// known) is deliberately NOT supported — an unknown language must not silently route to an
    /// engine that may not cover it. See `EngineRouter.choose`.
    public static func v3Supports(_ code: String?) -> Bool {
        guard let code else { return false }
        return v3.contains(Self.normalize(code))
    }

    /// `"EN-GB"`, `"en_US"`, `" En "` → `"en"`. Language settings reach Said from a picker, from
    /// Whisper's detector, and from a `.said` bundle written by another device, so the codes are not
    /// uniformly shaped.
    public static func normalize(_ code: String) -> String {
        let lower = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(lower.prefix { $0.isLetter })
    }
}

// MARK: - Routing

/// Chooses which engine transcribes a session.
///
/// Pure — no models, no audio, no I/O — so `--selftest-engine-route` can assert every branch
/// headlessly. That matters more here than anywhere else in Wave 2: routing is the one piece of the
/// engine swap that can silently produce an unusable transcript, and it is also the only piece that
/// can be tested completely without a GPU, a download, or a microphone.
public enum EngineRouter {

    /// Why a given engine was chosen. Surfaced verbatim in the session and in the UI, because
    /// "Parakeet ran and it was wrong" and "Whisper ran because your language isn't covered" need
    /// very different responses from the user.
    public struct Decision: Sendable, Equatable {
        public let engine: TranscriptionEngineID
        public let reason: String
        /// True when the router had to fall back from what the user or the default asked for. The UI
        /// says so rather than quietly substituting an engine.
        public let isFallback: Bool

        public init(engine: TranscriptionEngineID, reason: String, isFallback: Bool = false) {
            self.engine = engine
            self.reason = reason
            self.isFallback = isFallback
        }
    }

    /// Decide the engine for a session.
    ///
    /// - Parameters:
    ///   - preference: the user's Settings pick.
    ///   - language: the resolved language code, or `nil` when it is not yet known (an "Auto"
    ///     session whose detection has not run or has failed).
    ///   - parakeetInstalled: whether Parakeet's models are on disk and loadable.
    ///   - whisperInstalled: whether a Whisper model is on disk and loadable.
    ///
    /// **The `nil`-language rule is the important one.** An undetected language routes to Whisper,
    /// never to Parakeet. Parakeet asked to transcribe Hindi does not fail — it emits confident,
    /// fluent nonsense, which is far worse than being slow, and the user has no way to tell from the
    /// output that anything went wrong. Whisper covers the long tail, so guessing *toward* it costs
    /// speed and guessing away from it costs the transcript. §5.5 of the build prompt asks for
    /// exactly this: "never guess into an engine that cannot handle the language."
    public static func choose(preference: EnginePreference,
                              language: String?,
                              parakeetInstalled: Bool,
                              whisperInstalled: Bool) -> Decision {
        // An explicit user pick wins, and only degrades when the chosen engine is simply not there.
        switch preference {
        case .parakeet:
            if parakeetInstalled {
                return Decision(engine: .parakeet, reason: "Parakeet (your setting)")
            }
            if whisperInstalled {
                return Decision(engine: .whisper,
                                reason: "Whisper — Parakeet's models aren't downloaded", isFallback: true)
            }
            return Decision(engine: .parakeet, reason: "Parakeet (your setting)")

        case .whisper:
            if whisperInstalled {
                return Decision(engine: .whisper, reason: "Whisper (your setting)")
            }
            if parakeetInstalled {
                return Decision(engine: .parakeet,
                                reason: "Parakeet — no Whisper model is downloaded", isFallback: true)
            }
            return Decision(engine: .whisper, reason: "Whisper (your setting)")

        case .automatic:
            break
        }

        // Automatic. Language decides, and an unknown language is not a licence to guess.
        guard let language, !language.isEmpty else {
            if whisperInstalled {
                return Decision(engine: .whisper,
                                reason: "Whisper — the language isn't known yet", isFallback: false)
            }
            return Decision(engine: .parakeet,
                            reason: "Parakeet — the language isn't known and no Whisper model is downloaded",
                            isFallback: true)
        }

        let code = ParakeetLanguages.normalize(language)
        if ParakeetLanguages.v3.contains(code) {
            if parakeetInstalled {
                return Decision(engine: .parakeet, reason: "Parakeet")
            }
            if whisperInstalled {
                return Decision(engine: .whisper,
                                reason: "Whisper — Parakeet's models aren't downloaded", isFallback: true)
            }
            return Decision(engine: .parakeet, reason: "Parakeet")
        }

        // Outside Parakeet's set. This is the case the whole router exists for.
        if whisperInstalled {
            return Decision(engine: .whisper,
                            reason: "Whisper — Parakeet doesn't cover \(displayLanguage(code))")
        }
        return Decision(engine: .whisper,
                        reason: "Whisper is needed for \(displayLanguage(code)) but no Whisper model is downloaded",
                        isFallback: true)
    }

    /// A language code rendered for a status line ("Hindi", not "hi"), falling back to the raw code.
    public static func displayLanguage(_ code: String) -> String {
        Locale(identifier: "en_US_POSIX").localizedString(forLanguageCode: code) ?? code
    }
}

// MARK: - The provider seam

/// A live transcription session over a growing audio stream.
///
/// Deliberately the same three-call shape `StreamingTranscriber` already had (`run` / `stop` /
/// `snapshotSegments`), so `AppModel`'s streaming lifecycle — start a task, stop it, take the
/// confirmed segments for the live save — is unchanged by the engine swap. Requirements are `async`
/// so an actor can witness them directly.
public protocol TranscriptionStream: Sendable {
    /// Drive the stream until `stop()`. Called inside a `Task`.
    func run() async
    /// Stop delivering updates. Idempotent.
    func stop() async
    /// The CONFIRMED segments so far, for the immediate live save on stop.
    func snapshotSegments() async -> [TranscriptSegment]
}

/// One ASR family, behind a seam that names no vendor.
///
/// `TranscriptionEngine` selects a provider and every caller above it — `AppModel`, `Importer`, the
/// self-tests — keeps talking to `TranscriptionEngine`. That is why the seam is introduced *below*
/// the existing façade rather than in place of it: the façade's callers are the part of the tree
/// with the least test coverage, and the engine swap is already the largest regression risk in the
/// phase.
///
/// A future `AppleSpeechProvider` slots in here. It is deliberately NOT built — see
/// `CLAUDE.md` ▸ "Why Apple SpeechAnalyzer is deferred" for the four reasons and the
/// re-evaluation trigger.
public protocol TranscriptionProvider: AnyObject, Sendable {

    /// Stable identity, stored in `SessionMeta.engine`.
    static var engineID: TranscriptionEngineID { get }

    /// The languages this provider can be asked to transcribe. An EMPTY set means "no restriction"
    /// (multilingual Whisper), which is distinct from a set containing only `"en"` (an `*.en` model).
    var supportedLanguages: Set<String> { get }

    /// Whether `VocabularyBias` actually reaches the decoder on this provider *right now* — false
    /// when the mechanism exists but its prerequisites are missing (Parakeet's separate CTC spotter
    /// model, for instance). The UI says so rather than letting a pack look enabled but do nothing.
    var supportsVocabularyBias: Bool { get }

    /// Human-readable identifier of the loaded model, for `SessionMeta.engineModel`.
    var loadedModelName: String? { get }

    /// Download (once, with progress) + load. Idempotent for an already-loaded model.
    /// `progress` mirrors the `(message, fraction?)` shape the whole app already uses.
    func prepare(variant: String, progress: @escaping @Sendable (String, Double?) -> Void) async throws

    /// Full-quality pass over a whole buffer → timed segments (seconds from the audio buffer start,
    /// which is session T0). Carries word timings when the provider reports them.
    func transcribe(samples: [Float], language: String?, bias: VocabularyBias?) async throws -> [TranscriptSegment]

    /// Full-quality pass over an audio FILE, letting the provider do its own decoding (which is how
    /// both engines avoid holding a multi-hour file in memory).
    func transcribeFile(path: String, language: String?, bias: VocabularyBias?) async throws -> [TranscriptSegment]

    /// A live stream fed by `sink`. Returns `nil` when the provider is not loaded.
    func makeStream(sink: SampleSink, language: String?, bias: VocabularyBias?,
                    onUpdate: @escaping @Sendable (LiveTranscript) -> Void) async -> (any TranscriptionStream)?

    /// One-shot language identification over a lead-in buffer, or `nil` when this provider cannot
    /// identify languages at all. **Returning `nil` is a real answer, not a failure** — Parakeet has
    /// no language-ID head (verified at the pinned tag: `ASRResult` carries no detected language and
    /// `language:` is an input hint only), and the router has to know that rather than assume.
    func detectLanguage(samples: [Float]) async throws -> String?

    /// Release the loaded model. Called when switching engines mid-app so two 600 MB models do not
    /// sit resident for a session that only needs one.
    func unload() async
}

public extension TranscriptionProvider {
    /// Whether this provider can be asked for `language`. An empty `supportedLanguages` means
    /// unrestricted; a `nil` language means "not known yet", which is never an assertion of support.
    func supports(language: String?) -> Bool {
        if supportedLanguages.isEmpty { return true }
        guard let language else { return false }
        return supportedLanguages.contains(ParakeetLanguages.normalize(language))
    }
}
