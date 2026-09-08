import Foundation
import WhisperKit

/// The Whisper half of the engine seam (Phase 3, Wave 2).
///
/// This is a MOVE, not a rewrite: every decode option, the streaming confirmation algorithm and the
/// `promptTokens` biasing are exactly what `TranscriptionEngine` did before the seam existed, so a
/// session transcribed on Whisper after Phase 3 differs from one transcribed before it in only one
/// respect — the final pass now also asks for word timings. Everything else is byte-for-byte the
/// prior behaviour, which is what makes `stream-baseline-whisper.txt` a meaningful fixture.
///
/// **Naming hazard.** WhisperKit exports its own `WordTiming`, and SaidKit defines one. Swift
/// resolves an unqualified `WordTiming` inside SaidKit to SaidKit's, shadowing the import — but
/// silently, and this file legitimately handles both. Every mention below is therefore qualified.
public final class WhisperProvider: TranscriptionProvider, @unchecked Sendable {

    public static let engineID: TranscriptionEngineID = .whisper

    private let lock = NSLock()
    private var whisperKit: WhisperKit?
    private var loadedVariant: String?
    /// Variants whose alignment heads could not serve a word-timestamp request. Remembered so the
    /// fallback below costs at most one wasted pass per model per app run, not one per session.
    private var wordTimestampsUnsupported: Set<String> = []

    public init() {}

    // MARK: Identity

    public var loadedModelName: String? {
        lock.lock(); defer { lock.unlock() }
        return loadedVariant
    }

    /// An `*.en` model is English-only; every other Whisper variant is multilingual, which the seam
    /// spells as an EMPTY set ("no restriction") rather than by enumerating Whisper's ~99 languages.
    public var supportedLanguages: Set<String> {
        lock.lock(); defer { lock.unlock() }
        guard let loadedVariant else { return [] }
        return loadedVariant.hasSuffix(".en") ? ["en"] : []
    }

    /// Biasing needs the tokenizer, which only exists once a model is loaded.
    public var supportsVocabularyBias: Bool {
        lock.lock(); defer { lock.unlock() }
        return whisperKit?.tokenizer != nil
    }

    // MARK: Lifecycle

    public func prepare(variant: String, progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        lock.lock()
        let alreadyLoaded = (loadedVariant == variant && whisperKit != nil)
        lock.unlock()
        if alreadyLoaded { return }

        lock.lock(); whisperKit = nil; loadedVariant = nil; lock.unlock()

        // The gate is consulted BEFORE `WhisperKit.download`, which would otherwise reach the
        // network to check the repo even when the variant is already cached. An already-downloaded
        // model still loads below — the gate governs fetching, never loading.
        let cached = ModelStorage.whisperRoot.appendingPathComponent(variant, isDirectory: true)
        let isCached = FileManager.default.fileExists(atPath: cached.path)
        if !isCached { try ModelGate.requireDownloadAllowed("The \(variant) model") }

        progress("Downloading the \(variant) model", 0)
        let folder = try await WhisperKit.download(
            variant: variant,
            progressCallback: { p in progress("Downloading the \(variant) model", p.fractionCompleted) }
        )

        progress("Loading model…", nil)
        let config = WhisperKitConfig(
            model: variant,
            modelFolder: folder.path,
            load: true,      // REQUIRED: with modelFolder set and load:true, models actually load.
            download: false  // already downloaded above
        )
        let kit = try await WhisperKit(config)
        lock.lock(); whisperKit = kit; loadedVariant = variant; lock.unlock()
        progress("Model ready.", 1)
    }

    public func unload() async {
        lock.lock(); whisperKit = nil; loadedVariant = nil; lock.unlock()
    }

    // MARK: Bias

    /// Token IDs that bias decoding toward custom-vocabulary terms, via
    /// `DecodingOptions.promptTokens` conditioning. Unchanged from the pre-seam implementation,
    /// including the `suffix(111)` trim that matches WhisperKit's own.
    ///
    /// A `nil` bias returns `nil` — never `[]`, which would prepend a bare `<|startofprev|>` and
    /// change the prefill. `VocabularyBias` cannot be constructed empty, so this is now guaranteed
    /// by the type rather than by remembering to check.
    private func promptTokens(for bias: VocabularyBias?) -> [Int]? {
        guard let bias else { return nil }
        lock.lock(); let kit = whisperKit; lock.unlock()
        guard let tokenizer = kit?.tokenizer else { return nil }
        // Leading space = natural-continuation convention; commas separate glossary entries.
        let ids = tokenizer.encode(text: " " + bias.terms.joined(separator: ", "))
        let trimmed = Array(ids.suffix(111))   // (maxTokenContext 224 / 2) - 1, matching WhisperKit's trim
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Exposed for `--selftest-vocab`, which asserts the empty-list no-op directly.
    public func promptTokensForSelfTest(terms: [String]) -> [Int]? {
        promptTokens(for: VocabularyBias(terms: terms))
    }

    // MARK: Transcription

    public func transcribe(samples: [Float], language: String?, bias: VocabularyBias?) async throws -> [TranscriptSegment] {
        lock.lock(); let kit = whisperKit; let variant = loadedVariant; lock.unlock()
        guard let kit else { throw CaptureError.engineNotReady }
        guard samples.count > 1_600 else { return [] }   // < ~0.1 s of audio → nothing to do

        func run(wordTimestamps: Bool) async throws -> [TranscriptionResult] {
            var options = DecodingOptions(
                language: language,
                skipSpecialTokens: true,
                clipTimestamps: [],
                chunkingStrategy: .vad   // chunk on silence + decode chunks in parallel
            )
            options.promptTokens = promptTokens(for: bias)   // nil → byte-identical to the prior call
            options.wordTimestamps = wordTimestamps
            return try await kit.transcribe(audioArray: samples, decodeOptions: options)
        }

        // Word timings are worth asking for on the full-quality pass — they are what makes editing
        // and word-boundary speaker splits work on a Whisper session. But not every variant's
        // alignment heads can serve the request, and a save must NEVER fail over timings (§5.5), so
        // a throw falls back to a plain pass and the variant is remembered as unable.
        let wantWords = variant.map { !wordTimestampsUnsupported.contains($0) } ?? false
        let results: [TranscriptionResult]
        if wantWords {
            do {
                results = try await run(wordTimestamps: true)
            } catch {
                if let variant {
                    lock.lock(); wordTimestampsUnsupported.insert(variant); lock.unlock()
                }
                NSLog("[Whisper] word timestamps unavailable (\(error)); retrying without them")
                results = try await run(wordTimestamps: false)
            }
        } else {
            results = try await run(wordTimestamps: false)
        }
        return results.flatMap { $0.segments }.map(Self.segment(from:))
    }

    public func transcribeFile(path: String, language: String?, bias: VocabularyBias?) async throws -> [TranscriptSegment] {
        lock.lock(); let kit = whisperKit; lock.unlock()
        guard let kit else { throw CaptureError.engineNotReady }
        var options = DecodingOptions(language: language, skipSpecialTokens: true)
        options.promptTokens = promptTokens(for: bias)
        // WhisperKit 1.1.0's bounded-memory file reader. Opt-in (`.fullFile` is still the default)
        // and available on the `audioPath:` overload only, which is exactly this call — a
        // multi-hour lecture no longer has to be resident to be transcribed.
        let results = try await kit.transcribe(
            audioPath: path,
            audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
            decodeOptions: options
        )
        return results.flatMap { $0.segments }.map(Self.segment(from:))
    }

    /// Map WhisperKit's segment onto Said's, carrying word timings across when present.
    private static func segment(from s: TranscriptionSegment) -> TranscriptSegment {
        let start = TimeInterval(s.start)
        let end = TimeInterval(s.end)
        let words: [SaidKit.WordTiming]? = s.words.map { list in
            list.map { (w: WhisperKit.WordTiming) in
                SaidKit.WordTiming(text: w.word,
                                   start: TimeInterval(w.start),
                                   end: TimeInterval(w.end),
                                   confidence: w.probability)
            }
        }
        return TranscriptSegment(start: start, end: end,
                                 text: TranscriptText.clean(s.text),
                                 words: words)
    }

    // MARK: Language identification

    /// One-shot language detection over a lead-in sample (multilingual models only — WhisperKit
    /// throws for `*.en` decoders).
    ///
    /// NOTE: at the pinned tag the array-based API is literally spelled `detectLangauge(audioArray:)`
    /// [sic]; only the `audioPath:` variant got the correct spelling. Verified unchanged at 1.1.0.
    public func detectLanguage(samples: [Float]) async throws -> String? {
        lock.lock(); let kit = whisperKit; lock.unlock()
        guard let kit else { throw CaptureError.engineNotReady }
        return try await kit.detectLangauge(audioArray: samples).language
    }

    /// The full detector result, for `--selftest-detect` and the status line's probability display.
    public func detectLanguageDetailed(samples: [Float]) async throws -> (language: String, probs: [String: Float]) {
        lock.lock(); let kit = whisperKit; lock.unlock()
        guard let kit else { throw CaptureError.engineNotReady }
        let r = try await kit.detectLangauge(audioArray: samples)
        return (r.language, r.langProbs)
    }

    // MARK: Streaming

    public func makeStream(sink: SampleSink, language: String?, bias: VocabularyBias?,
                           onUpdate: @escaping @Sendable (LiveTranscript) -> Void) async -> (any TranscriptionStream)? {
        lock.lock(); let kit = whisperKit; lock.unlock()
        guard let kit else { return nil }
        return StreamingTranscriber(whisperKit: kit, sink: sink, language: language,
                                    promptTokens: promptTokens(for: bias), onUpdate: onUpdate)
    }
}

// MARK: - Whisper's live transcriber

/// Live transcription over a growing audio buffer. Mirrors WhisperKit's own
/// `AudioStreamTranscriber` confirmation algorithm (which is mic-only and cannot be reused for
/// system audio): re-transcribe from the last confirmed timestamp each pass, confirm all but the
/// trailing `requiredSegmentsForConfirmation` segments, and keep the rest as a live hypothesis.
/// `clipTimestamps: [lastConfirmedEnd]` avoids re-decoding confirmed audio, which also prevents
/// duplicated text across passes.
///
/// **Unchanged by Phase 3, deliberately.** Whisper's decoder has no incremental-window entry point
/// — `transcribe(audioArray:)` takes a whole array — so the per-pass buffer read stays. What Phase 3
/// changes is which engine is DEFAULT: Parakeet streams through a manager that buffers internally
/// and bounds its own memory (see `ParakeetStream`), so the full-buffer pass is no longer on the
/// common path. The Whisper streamer keeps its old behaviour rather than acquiring a half-fix.
public actor StreamingTranscriber: TranscriptionStream {
    private let whisperKit: WhisperKit
    private let sink: SampleSink
    private let language: String?
    private let promptTokens: [Int]?
    private let onUpdate: @Sendable (LiveTranscript) -> Void
    private let requiredSegmentsForConfirmation = 2

    private var running = false
    private var lastProcessedCount = 0
    private var lastConfirmedEnd: Float = 0
    private var confirmedSegments: [TranscriptionSegment] = []

    init(whisperKit: WhisperKit, sink: SampleSink, language: String?, promptTokens: [Int]? = nil,
         onUpdate: @escaping @Sendable (LiveTranscript) -> Void) {
        self.whisperKit = whisperKit
        self.sink = sink
        self.language = language
        self.promptTokens = promptTokens
        self.onUpdate = onUpdate
    }

    public func run() async {
        running = true
        while running {
            let samples = sink.snapshot()
            let newSamples = samples.count - lastProcessedCount
            let newSeconds = Float(newSamples) / Float(WhisperKit.sampleRate)

            // Wait until at least ~1s of fresh audio has accumulated.
            guard newSeconds > 1.0 else {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            lastProcessedCount = samples.count

            do {
                var options = DecodingOptions(
                    language: language,
                    skipSpecialTokens: true,
                    clipTimestamps: [lastConfirmedEnd]
                )
                options.promptTokens = promptTokens   // nil → byte-identical to the prior streaming call
                let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
                guard running else { break }
                applySegments(results.flatMap { $0.segments })
            } catch {
                NSLog("[Stream] transcribe error: \(error)")
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    public func stop() {
        running = false
    }

    /// Confirmed segments so far, as timed `TranscriptSegment`s (for the live document save).
    public func snapshotSegments() -> [TranscriptSegment] {
        confirmedSegments.map {
            TranscriptSegment(start: TimeInterval($0.start), end: TimeInterval($0.end),
                              text: TranscriptText.clean($0.text))
        }
    }

    private func applySegments(_ segments: [TranscriptionSegment]) {
        var unconfirmed: [TranscriptionSegment] = segments

        if segments.count > requiredSegmentsForConfirmation {
            let confirmCount = segments.count - requiredSegmentsForConfirmation
            let toConfirm = Array(segments.prefix(confirmCount))
            unconfirmed = Array(segments.suffix(requiredSegmentsForConfirmation))

            if let last = toConfirm.last, last.end > lastConfirmedEnd {
                lastConfirmedEnd = last.end
                confirmedSegments.append(contentsOf: toConfirm)
            }
        }

        // Surface confirmed (timestamped) segments + the trailing hypothesis separately so the UI
        // can render the locked text solid and the in-flight tail dimmed with a caret.
        let confirmed = confirmedSegments.map {
            TranscriptSegment(start: TimeInterval($0.start), end: TimeInterval($0.end),
                              text: TranscriptText.clean($0.text))
        }
        let hypothesis = unconfirmed.map { $0.text }.joined()
        onUpdate(LiveTranscript(confirmed: confirmed, hypothesis: hypothesis))
    }
}
