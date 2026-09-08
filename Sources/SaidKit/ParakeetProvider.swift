import Foundation
import AVFoundation
import FluidAudio

/// The Parakeet half of the engine seam (Phase 3, Wave 2) — NVIDIA Parakeet TDT via FluidAudio's
/// CoreML port, on the ANE.
///
/// Three things make it the right default, and each is a fact rather than a benchmark claim:
/// 1. **Word timings come free.** `ASRResult.tokenTimings` is populated on both the batch and the
///    streaming path, with no DTW pass and no second model. Whisper only produces them on request,
///    at a cost, and never on the live path. Wave 1's whole substrate rests on this.
/// 2. **Streaming is incremental by construction.** `SlidingWindowAsrManager` buffers internally and
///    trims what it has consumed, so the caller pushes new audio and never re-hands it the session.
///    That is the direct fix for §5.3's full-buffer copy.
/// 3. **Its confirmed/volatile split is already Said's UI contract.** `SlidingWindowTranscriptionUpdate.
///    isConfirmed` maps 1:1 onto `LiveTranscript { confirmed, hypothesis }`, so the amber live tail
///    keeps working with no reinterpretation.
///
/// **Every API below was read at the pinned tag (v0.15.2, `7f963cd`), not from documentation.** The
/// vendor's README, ASR guide and model card disagree with each other about the loading call —
/// `initialize(models:)`, `configure(models:)` and `loadModels(_:)` all appear in print. Only
/// `loadModels(_:)` exists. See `PHASE3-REPORT.md`.
public final class ParakeetProvider: TranscriptionProvider, @unchecked Sendable {

    public static let engineID: TranscriptionEngineID = .parakeet

    /// Which Parakeet model to load. Said ships v3 and nothing else by default — see
    /// `CLAUDE.md` ▸ "Parakeet's language coverage" for why the Japanese and Mandarin
    /// models, which exist as first-class cases in FluidAudio's enum, are deliberately not wired up.
    public enum Variant: String, Sendable, CaseIterable {
        case v3        // parakeet-tdt-0.6b-v3-coreml — multilingual
        case v2        // parakeet-tdt-0.6b-v2-coreml — English only

        var asrVersion: AsrModelVersion { self == .v3 ? .v3 : .v2 }
        var languages: Set<String> { self == .v3 ? ParakeetLanguages.v3 : ParakeetLanguages.v2 }
        public var displayName: String { self == .v3 ? "Parakeet v3 (multilingual)" : "Parakeet v2 (English)" }
    }

    private let lock = NSLock()
    private var models: AsrModels?
    private var manager: AsrManager?
    private var variant: Variant = .v3
    /// The separate CTC keyword-spotting model that vocabulary boosting needs. Loaded lazily and
    /// ONLY when a bias is actually in play, because it is a second download the user should not pay
    /// for unless they use custom vocabulary or a vertical pack.
    private var ctcModels: CtcModels?
    private var ctcUnavailable = false

    public init() {}

    // MARK: Identity

    public var loadedModelName: String? {
        lock.lock(); defer { lock.unlock() }
        return models == nil ? nil : variant.rawValue
    }

    public var supportedLanguages: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return variant.languages
    }

    /// Vocabulary boosting needs the CTC spotter alongside the TDT model. Reporting `false` when it
    /// could not be obtained is the honest answer: the UI can then say a pack is enabled but not
    /// biasing, rather than letting the user believe recognition is being steered when it is not.
    public var supportsVocabularyBias: Bool {
        lock.lock(); defer { lock.unlock() }
        return !ctcUnavailable
    }

    // MARK: Lifecycle

    public func prepare(variant variantRaw: String, progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        let want = Variant(rawValue: variantRaw) ?? .v3
        lock.lock()
        let alreadyLoaded = (models != nil && variant == want)
        lock.unlock()
        if alreadyLoaded { return }

        let cacheDir = AsrModels.defaultCacheDirectory(for: want.asrVersion)
        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            try ModelGate.requireDownloadAllowed("The \(want.displayName) model")
        }

        progress("Downloading the \(want.displayName) model", 0)
        let loaded = try await AsrModels.downloadAndLoad(
            version: want.asrVersion,
            progressHandler: { p in
                progress("Downloading the \(want.displayName) model", p.fractionCompleted)
            }
        )
        progress("Loading model…", nil)
        let mgr = AsrManager(config: .default)
        try await mgr.loadModels(loaded)

        lock.lock()
        models = loaded
        manager = mgr
        variant = want
        lock.unlock()
        progress("Model ready.", 1)
    }

    public func unload() async {
        lock.lock()
        let mgr = manager
        models = nil; manager = nil; ctcModels = nil; ctcUnavailable = false
        lock.unlock()
        await mgr?.cleanup()
    }

    /// Fetch (once) the CTC keyword-spotting model that vocabulary boosting rides on.
    ///
    /// A failure here is NOT a transcription failure: the session still runs, unbiased, and
    /// `supportsVocabularyBias` starts reporting false so the UI can say so. Refusing to transcribe
    /// because a *bias* model is missing would be the wrong trade every time.
    private func loadCtcModelsIfNeeded() async -> CtcModels? {
        lock.lock()
        if let existing = ctcModels { lock.unlock(); return existing }
        if ctcUnavailable { lock.unlock(); return nil }
        lock.unlock()

        do {
            let dir = CtcModels.defaultCacheDirectory(for: .ctc110m)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try ModelGate.requireDownloadAllowed("The custom-vocabulary model")
            }
            let loaded = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            lock.lock(); ctcModels = loaded; lock.unlock()
            return loaded
        } catch {
            NSLog("[Parakeet] custom-vocabulary model unavailable (\(error)); transcribing without bias")
            lock.lock(); ctcUnavailable = true; lock.unlock()
            return nil
        }
    }

    /// Said's engine-neutral bias → FluidAudio's context.
    ///
    /// **A caveat worth surfacing rather than burying:** `CustomVocabularyContext.minTermLength`
    /// defaults to 3 and terms shorter than that are dropped by the library, following the NeMo
    /// CTC-WS paper's finding that very short terms produce more false substitutions than
    /// corrections. So a two-letter acronym in a vertical pack will not bias Parakeet. Said keeps
    /// the library default rather than forcing it lower — a spurious "VR" every time someone says
    /// "or" is a worse transcript than a missed boost.
    private func vocabularyContext(_ bias: VocabularyBias) -> CustomVocabularyContext {
        CustomVocabularyContext(terms: bias.terms.map { CustomVocabularyTerm(text: $0) })
    }

    private func fluidLanguage(_ code: String?) -> FluidAudio.Language? {
        guard let code else { return nil }
        return FluidAudio.Language(rawValue: ParakeetLanguages.normalize(code))
    }

    // MARK: Batch transcription

    public func transcribe(samples: [Float], language: String?, bias: VocabularyBias?) async throws -> [TranscriptSegment] {
        lock.lock(); let mgr = manager; lock.unlock()
        guard let mgr else { throw CaptureError.engineNotReady }
        // FluidAudio throws `ASRError.invalidAudioData` below `minimumRequiredSamples` — 4 800
        // samples (0.3 s) at 16 kHz, verified at the pinned tag. Returning empty is the right
        // answer for a fragment that short anyway; letting it throw would fail a save over it.
        guard samples.count >= 4_800 else { return [] }

        var state = TdtDecoderState.make(decoderLayers: await mgr.decoderLayerCount)
        let result = try await mgr.transcribe(samples, decoderState: &state,
                                              language: fluidLanguage(language))

        var words = Self.words(from: result)
        if let bias, !words.isEmpty {
            words = await applyVocabularyBias(bias, to: words, transcript: result.text,
                                              tokenTimings: result.tokenTimings ?? [], samples: samples)
        }
        guard !words.isEmpty else {
            return TranscriptAssembly.singleSegment(text: result.text,
                                                    duration: Double(samples.count) / 16_000.0)
        }
        let segs = TranscriptAssembly.segments(words: words)
        return segs.isEmpty
            ? TranscriptAssembly.singleSegment(text: result.text, duration: Double(samples.count) / 16_000.0)
            : segs
    }

    // MARK: Vocabulary biasing on the BATCH path

    /// Bias the FINAL pass toward the custom vocabulary.
    ///
    /// **This has to be assembled by hand, and that is a finding rather than an oversight.**
    /// `AsrManager` has no vocabulary API at all at the pinned tag: the only wired-up biasing is on
    /// `SlidingWindowAsrManager`, i.e. the LIVE path. The live text is transient; the batch pass is
    /// what produces the transcript that gets saved, searched, exported and summarised. Shipping
    /// biasing on the streaming path alone would mean the vertical packs appeared to work while
    /// every saved transcript came out unbiased — precisely the "packs silently inert" outcome §5.4
    /// says to stop the build over. So the three public pieces the streaming manager composes
    /// internally — `CtcKeywordSpotter`, `VocabularyRescorer`, `ctcTokenRescore` — are composed here
    /// too, in the same order and with the same vocabulary-size-aware configuration.
    ///
    /// **The mechanism is post-hoc CTC rescoring, not decode-time biasing.** Parakeet TDT decodes
    /// normally, then a CTC keyword spotter's log-probability matrix is used to ask, for each word,
    /// whether a vocabulary term scores better acoustically than what TDT actually emitted. That
    /// costs a second encoder pass over the audio, which is why it only runs when there is a
    /// vocabulary to apply.
    ///
    /// Replacements are applied to the WORD ARRAY rather than to the joined text, so the corrected
    /// spelling keeps the timing of the sound it replaced and `words`/`text` cannot drift apart.
    /// Every failure here degrades to the unbiased transcript; none of it can fail a save.
    private func applyVocabularyBias(_ bias: VocabularyBias, to words: [WordTiming],
                                     transcript: String, tokenTimings: [TokenTiming],
                                     samples: [Float]) async -> [WordTiming] {
        guard !tokenTimings.isEmpty, let ctc = await loadCtcModelsIfNeeded() else { return words }
        let vocab = vocabularyContext(bias)
        do {
            let spotter = CtcKeywordSpotter(models: ctc, blankId: ctc.vocabulary.count)
            let spotted = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples,
                                                                     customVocabulary: vocab,
                                                                     minScore: nil)
            guard !spotted.logProbs.isEmpty else { return words }

            let ctcDir = CtcModels.defaultCacheDirectory(for: ctc.variant)
            let rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: vocab,
                                                               ctcModelDirectory: ctcDir)
            let sizing = ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count)
            let output = rescorer.ctcTokenRescore(
                transcript: transcript,
                tokenTimings: tokenTimings,
                logProbs: spotted.logProbs,
                frameDuration: spotted.frameDuration,
                cbw: sizing.cbw,
                marginSeconds: 0.5,
                minSimilarity: max(sizing.minSimilarity, vocab.minSimilarity)
            )
            guard output.wasModified else { return words }
            let pairs = output.replacements
                .filter { $0.shouldReplace }
                .compactMap { r -> (String, String)? in r.replacementWord.map { (r.originalWord, $0) } }
            NSLog("[Parakeet] vocabulary applied to \(pairs.count) word(s) in the final pass")
            return Self.applying(replacements: pairs, to: words)
        } catch {
            NSLog("[Parakeet] vocabulary rescoring failed (\(error)); keeping the unbiased transcript")
            return words
        }
    }

    /// Substitute rescored spellings into the word array, preserving each word's timing.
    ///
    /// Consumes one replacement per matching occurrence, in order, mirroring how the rescorer
    /// reports them. Matching ignores case and surrounding punctuation, because the rescorer works
    /// on bare words while the word array carries the punctuation the decoder emitted.
    static func applying(replacements: [(String, String)], to words: [WordTiming]) -> [WordTiming] {
        guard !replacements.isEmpty else { return words }
        var pending = replacements
        var out = words
        for i in out.indices {
            let bare = out[i].text.trimmingCharacters(in: .punctuationCharacters).lowercased()
            guard let j = pending.firstIndex(where: {
                $0.0.trimmingCharacters(in: .punctuationCharacters).lowercased() == bare
            }) else { continue }
            let (_, replacement) = pending.remove(at: j)
            // Keep whatever punctuation the decoder attached to the END of the original word, so a
            // sentence-final "anastomosis." does not lose its full stop to the correction.
            // Written as a plain loop rather than a `reversed().prefix(while:).reversed()` chain:
            // the chain is three layers of generic wrappers deep and its inference is not worth
            // betting on in code that could not be compiled when it was written.
            var tail: [Character] = []
            for ch in out[i].text.reversed() {
                guard ch.isPunctuation else { break }
                tail.insert(ch, at: 0)
            }
            out[i] = WordTiming(text: replacement + String(tail),
                                start: out[i].start, end: out[i].end, confidence: out[i].confidence)
            if pending.isEmpty { break }
        }
        return out
    }

    public func transcribeFile(path: String, language: String?, bias: VocabularyBias?) async throws -> [TranscriptSegment] {
        lock.lock(); let mgr = manager; lock.unlock()
        guard let mgr else { throw CaptureError.engineNotReady }
        let url = URL(fileURLWithPath: path)
        var state = TdtDecoderState.make(decoderLayers: await mgr.decoderLayerCount)
        // The URL overload picks its own disk-backed path above `config.streamingThreshold`
        // (~30 s), so a multi-hour lecture is never resident in full.
        let result = try await mgr.transcribe(url, decoderState: &state, language: fluidLanguage(language))
        return Self.segments(from: result, fallbackDuration: result.duration)
    }

    /// `ASRResult`'s token timings folded into whole words. Empty when the engine reported none.
    static func words(from result: ASRResult) -> [WordTiming] {
        guard let timings = result.tokenTimings, !timings.isEmpty else { return [] }
        return TranscriptAssembly.words(fromTokens: timings.map {
            (text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence)
        })
    }

    /// `ASRResult` → Said's segments, via the pure assembler.
    static func segments(from result: ASRResult, fallbackDuration: TimeInterval) -> [TranscriptSegment] {
        let words = Self.words(from: result)
        // §5.5: timings absent or malformed must never fail a save. One honest coarse segment.
        guard !words.isEmpty else {
            return TranscriptAssembly.singleSegment(text: result.text, duration: fallbackDuration)
        }
        let segs = TranscriptAssembly.segments(words: words)
        // A pathological timing array (all zero-length, all at t=0) would assemble to nothing while
        // the text is perfectly good. Prefer the text.
        return segs.isEmpty ? TranscriptAssembly.singleSegment(text: result.text, duration: fallbackDuration) : segs
    }

    // MARK: Language identification — deliberately absent

    /// Parakeet cannot identify a language, and saying so is the correct answer.
    ///
    /// Verified at the pinned tag: `ASRResult` carries no detected-language field, and the
    /// `language:` parameter on every `transcribe` overload is an INPUT hint used for script-aware
    /// token filtering, not an output. §5.2a's first candidate strategy ("Parakeet self-reports") is
    /// therefore refuted by source, not by experiment. Returning `nil` — rather than guessing "en" —
    /// is what lets `EngineRouter` route an unknown language to Whisper instead of into an engine
    /// that would answer fluently and wrongly.
    public func detectLanguage(samples: [Float]) async throws -> String? { nil }

    // MARK: Streaming

    public func makeStream(sink: SampleSink, language: String?, bias: VocabularyBias?,
                           onUpdate: @escaping @Sendable (LiveTranscript) -> Void) async -> (any TranscriptionStream)? {
        lock.lock(); let loaded = models; lock.unlock()
        guard let loaded else { return nil }

        let sw = SlidingWindowAsrManager(config: .streaming)
        do {
            try await sw.loadModels(loaded)
            if let bias {
                if let ctc = await loadCtcModelsIfNeeded() {
                    try await sw.configureVocabularyBoosting(vocabulary: vocabularyContext(bias), ctcModels: ctc)
                }
                // No CTC models → no boosting, but the session still records. Logged in the loader.
            }
            try await sw.startStreaming(source: .microphone)
        } catch {
            NSLog("[Parakeet] could not start the streaming engine: \(error)")
            return nil
        }
        return ParakeetStream(manager: sw, sink: sink, onUpdate: onUpdate)
    }
}

// MARK: - Parakeet's live stream

/// Feeds the sliding-window manager incrementally and republishes its updates as `LiveTranscript`.
///
/// **The pump is the point.** It reads only what has arrived since its last pass
/// (`SampleSink.newSamples(after:)`) and hands it straight to the manager, which owns its own
/// windowing and trims what it has consumed. Nothing here holds the session's audio, so live memory
/// is flat in session length rather than linear — the defect §5.3 exists to fix.
public actor ParakeetStream: TranscriptionStream {

    private let manager: SlidingWindowAsrManager
    private let sink: SampleSink
    private let onUpdate: @Sendable (LiveTranscript) -> Void

    private var running = false
    private var readIndex = 0
    private var pumpTask: Task<Void, Never>?

    /// Every word confirmed so far, in order. Segments are re-assembled from these on each update so
    /// the live transcript is cut the same way the final one will be.
    private var confirmedWords: [WordTiming] = []
    private var hypothesis = ""

    init(manager: SlidingWindowAsrManager, sink: SampleSink,
         onUpdate: @escaping @Sendable (LiveTranscript) -> Void) {
        self.manager = manager
        self.sink = sink
        self.onUpdate = onUpdate
    }

    public func run() async {
        running = true

        // Push audio in on its own task; consuming updates below must not stall the feed.
        pumpTask = Task { [weak self] in
            while await self?.isRunning == true {
                await self?.pumpOnce()
                try? await Task.sleep(nanoseconds: 100_000_000)   // 10 Hz — well inside the window size
            }
        }

        // `transcriptionUpdates` installs a fresh continuation each time it is READ, replacing any
        // previous one, so it is read exactly once here and iterated.
        for await update in await manager.transcriptionUpdates {
            guard running else { break }
            apply(update)
        }
    }

    private var isRunning: Bool { running }

    /// One incremental read → the manager. Bounded by whatever arrived in the last ~100 ms.
    ///
    /// Awaited inline rather than spawned into a `Task`: `AVAudioPCMBuffer` is not `Sendable`, so
    /// handing it to a detached task would cross an isolation boundary with a reference type that
    /// makes no thread-safety promise. Awaiting keeps the buffer on one hop from creation to
    /// consumption, and the manager's own input is an `AsyncStream` continuation, so the await is
    /// a yield, not a stall.
    private func pumpOnce() async {
        let (samples, next) = sink.newSamples(after: readIndex)
        readIndex = next
        guard !samples.isEmpty, let buffer = Self.pcmBuffer(from: samples) else { return }
        await manager.streamAudio(buffer)
    }

    private func apply(_ update: SlidingWindowTranscriptionUpdate) {
        let words = TranscriptAssembly.words(fromTokens: update.tokenTimings.map {
            (text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence)
        })
        if update.isConfirmed {
            // Timings arrive already offset to session-absolute time (the manager applies its
            // window's global frame offset before emitting), and the sink starts at session T0 with
            // paused audio dropped by `CaptureGate` — so a word's time is on the same
            // pause-compressed clock as every bookmark, frame and `[mm:ss]`.
            confirmedWords.append(contentsOf: words)
            hypothesis = ""
        } else {
            hypothesis = update.text
        }
        let confirmed = TranscriptAssembly.segments(words: confirmedWords)
        onUpdate(LiveTranscript(confirmed: confirmed, hypothesis: hypothesis))
    }

    public func stop() {
        running = false
        pumpTask?.cancel()
        pumpTask = nil
        let mgr = manager
        Task { await mgr.cancel() }
    }

    public func snapshotSegments() -> [TranscriptSegment] {
        TranscriptAssembly.segments(words: confirmedWords)
    }

    /// 16 kHz mono Float32 → `AVAudioPCMBuffer`, the currency the manager takes.
    ///
    /// The samples are ALREADY at the manager's own rate (Said resamples once, at capture, in
    /// `Resampler16k`), so its internal `AudioConverter` sees matching formats and does no work.
    /// Resampling here as well — which the vendor's mic examples do — would be a second conversion
    /// of audio that is already correct.
    nonisolated static func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
