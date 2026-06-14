import Foundation
import WhisperKit

/// The live transcription state surfaced to the UI: confirmed (locked, timestamped) segments
/// plus the trailing in-flight hypothesis. `text` is the full concatenation used for saving /
/// summarizing (kept identical to the prior behavior).
struct LiveTranscript: Sendable {
    var confirmed: [TranscriptSegment]
    var hypothesis: String
    var text: String { TranscriptText.clean(confirmed.map { $0.text }.joined() + hypothesis) }
}

/// Wraps WhisperKit: downloads/loads a model (with progress), provides the streaming
/// rolling-window transcriber, and a one-shot full-quality pass over the whole recording.
final class TranscriptionEngine: @unchecked Sendable {
    let sink = SampleSink()

    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    var isReady: Bool { whisperKit != nil }
    var sampleCount: Int { sink.count }

    /// Downloads (first run, with progress) and loads the given model. No-op if already loaded.
    /// `progress` is invoked with a human-readable message and an optional download fraction (0…1).
    func prepare(model: String, progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        if loadedModel == model, whisperKit != nil { return }

        // Release any previously-loaded model before switching.
        whisperKit = nil
        loadedModel = nil

        progress("Downloading the \(model) model", 0)
        // Pre-download so we can surface progress; returns instantly if already cached (offline-OK).
        let folder = try await WhisperKit.download(
            variant: model,
            progressCallback: { p in
                progress("Downloading the \(model) model", p.fractionCompleted)
            }
        )

        progress("Loading model…", nil)
        let config = WhisperKitConfig(
            model: model,
            modelFolder: folder.path,
            load: true,      // REQUIRED: with modelFolder set and load:true, models actually load.
            download: false  // already downloaded above
        )
        whisperKit = try await WhisperKit(config)
        loadedModel = model
        progress("Model ready.", 1)
    }

    /// Build a streaming transcriber bound to the loaded model + shared sink. `promptTokens` biases
    /// decoding toward custom-vocabulary terms (nil → no bias; see `promptTokens(for:)`).
    func makeStreamer(language: String?, promptTokens: [Int]? = nil,
                      onUpdate: @escaping @Sendable (LiveTranscript) -> Void) -> StreamingTranscriber? {
        guard let whisperKit else { return nil }
        return StreamingTranscriber(whisperKit: whisperKit, sink: sink, language: language,
                                    promptTokens: promptTokens, onUpdate: onUpdate)
    }

    /// Token IDs that bias decoding toward custom-vocabulary terms (names / acronyms / jargon), via
    /// WhisperKit's `DecodingOptions.promptTokens` conditioning. An empty/whitespace term list returns
    /// **nil** — an EXACT no-op (the decoder's prefill is byte-identical to today). Never returns `[]`
    /// (which would prepend a bare <|startofprev|> and change the prefill).
    func promptTokens(for terms: [String]) -> [Int]? {
        guard let whisperKit, let tokenizer = whisperKit.tokenizer else { return nil }
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        // Leading space = natural-continuation convention; commas separate glossary entries.
        let ids = tokenizer.encode(text: " " + cleaned.joined(separator: ", "))
        let trimmed = Array(ids.suffix(111))   // (maxTokenContext 224 / 2) - 1, matching WhisperKit's trim
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One-shot language detection over a lead-in sample (multilingual models only — WhisperKit
    /// throws for `*.en` decoders). Used by the "Auto" language path: detect ONCE, then pin the
    /// result for all streaming windows + the final pass.
    /// NOTE: at the pinned WhisperKit 1.0.0 tag the array-based API is literally spelled
    /// `detectLangauge(audioArray:)` [sic] — only the `audioPath:` variant got the correct spelling.
    func detectLanguage(samples: [Float]) async throws -> (language: String, probs: [String: Float]) {
        guard let whisperKit else { throw CaptureError.engineNotReady }
        let result = try await whisperKit.detectLangauge(audioArray: samples)
        return (result.language, result.langProbs)
    }

    /// One-shot full-quality transcription of an audio FILE (any format/sample rate —
    /// WhisperKit decodes + resamples to 16 kHz mono internally). Used by `--selftest`.
    func transcribeFile(_ path: String, language: String?, promptTokens: [Int]? = nil) async throws -> String {
        guard let whisperKit else { throw CaptureError.engineNotReady }
        var options = DecodingOptions(language: language, skipSpecialTokens: true)
        options.promptTokens = promptTokens
        let results = try await whisperKit.transcribe(audioPath: path, decodeOptions: options)
        return TranscriptText.clean(results.map { $0.text }.joined(separator: " "))
    }

    /// One full-quality, non-streaming pass over the entire recorded audio (the shared sink),
    /// returning timed segments (seconds relative to the audio buffer start == session T0).
    func finalPassSegments(language: String?, promptTokens: [Int]? = nil) async throws -> [TranscriptSegment] {
        try await transcribeSamples(sink.snapshot(), language: language, promptTokens: promptTokens)
    }

    /// Full-quality, VAD-chunked transcription of an explicit sample buffer → timed segments. Shared
    /// by the live `finalPass` and the file/video import path. `promptTokens` applies the vocab bias.
    func transcribeSamples(_ samples: [Float], language: String?, promptTokens: [Int]? = nil) async throws -> [TranscriptSegment] {
        guard let whisperKit else { throw CaptureError.engineNotReady }
        guard samples.count > 1_600 else { return [] } // < ~0.1s of audio → nothing to do
        var options = DecodingOptions(
            language: language,
            skipSpecialTokens: true,
            clipTimestamps: [],
            chunkingStrategy: .vad   // chunk on silence + decode chunks in parallel for accuracy/speed
        )
        options.promptTokens = promptTokens   // nil → byte-identical to the prior call
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap { $0.segments }.map {
            TranscriptSegment(start: TimeInterval($0.start), end: TimeInterval($0.end),
                              text: TranscriptText.clean($0.text))
        }
    }

    /// One full-quality, non-streaming pass returning plain joined text (used by self-tests).
    func finalPass(language: String?, promptTokens: [Int]? = nil) async throws -> String {
        let segments = try await finalPassSegments(language: language, promptTokens: promptTokens)
        return TranscriptText.clean(segments.map { $0.text }.joined(separator: " "))
    }
}

/// Live transcription over a growing audio buffer. Mirrors WhisperKit's own
/// AudioStreamTranscriber confirmation algorithm (which is mic-only and cannot be reused
/// for system audio): re-transcribe from the last confirmed timestamp each pass, confirm
/// all but the trailing `requiredSegmentsForConfirmation` segments, and keep the rest as a
/// live hypothesis. `clipTimestamps: [lastConfirmedEnd]` avoids re-decoding confirmed audio,
/// which also prevents duplicated text across passes.
actor StreamingTranscriber {
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

    func run() async {
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

    func stop() {
        running = false
    }

    /// Confirmed segments so far, as timed `TranscriptSegment`s (for the live document save).
    func snapshotSegments() -> [TranscriptSegment] {
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

/// Small text tidy-up shared by streaming + final passes.
enum TranscriptText {
    static func clean(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "  ", with: " ")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
