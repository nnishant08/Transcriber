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
/// 2. **Streaming stays incremental** — but NOT through `SlidingWindowAsrManager`. That was the
///    first implementation and it was measured to drop 27% of the words live (see `ParakeetStream`
///    for the numbers and why). The live path is now a bounded rolling window over the batch
///    `transcribe(samples:)`, read through `SampleSink.newSamples(after:)`, so §5.3's full-buffer
///    copy stays fixed: what is copied per tick is the window, never the session.
/// 3. **It is fast enough to re-transcribe.** 241× realtime on the ANE means a 20 s live window
///    costs ~80 ms a second — which is what lets the live words come from the same code path as
///    the saved transcript instead of a second, weaker decoder.
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
        // `boundarySearchFrames: 0` switches OFF stage 3 of FluidAudio's chunk-join token dedup —
        // the "bounded substring" search that looks for any short run from the previous chunk's
        // last 15 tokens anywhere in the next chunk's opening and deletes everything before it.
        // On real speech it matches a single common token and throws the words in front of it
        // away: measured on a lecture (2026-09-14), the batch pass rendered "critical boundaries
        // on our sampling distribution to create" as "quick to create". Stage 2 — the exact
        // suffix/prefix match that removes the genuine 2 s overlap — is untouched, and on the v3
        // decoder this field has no other reader (verified at 0.15.2: only `TdtDecoderV2` uses it).
        let mgr = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(boundarySearchFrames: 0)))
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

    /// Said's engine-neutral bias → FluidAudio's context, **with the terms tokenized**.
    ///
    /// **The tokenization is not optional and its absence is silent.** Both rescoring paths do
    /// `let vocabTokens = term.ctcTokenIds ?? term.tokenIds` and then
    /// `guard let vocabTokens, !vocabTokens.isEmpty else { continue }` — so a term built as
    /// `CustomVocabularyTerm(text:)` alone, with both id arrays nil, is skipped outright. Every term
    /// would be skipped, the rescorer would find nothing to do, and custom vocabulary and the
    /// vertical packs would be a complete no-op that reported success. That is exactly the "packs
    /// silently inert" outcome §5.4 says to stop the build over, and it is invisible from the
    /// outside: the transcript is fine, it is just unbiased.
    ///
    /// This mirrors the vendor's own `CustomVocabularyContext.loadWithCtcTokens`, which is the only
    /// place in their tree that builds a usable context — a strong hint that the plain initializer
    /// is a data holder, not an entry point.
    ///
    /// **A caveat worth surfacing rather than burying:** `CustomVocabularyContext.minTermLength`
    /// defaults to 3 and terms shorter than that are dropped by the library, following the NeMo
    /// CTC-WS paper's finding that very short terms produce more false substitutions than
    /// corrections. So a two-letter acronym in a vertical pack will not bias Parakeet. Said keeps
    /// the library default rather than forcing it lower — a spurious "VR" every time someone says
    /// "or" is a worse transcript than a missed boost.
    ///
    /// Returns `nil` when nothing survived tokenization, so the caller skips biasing entirely rather
    /// than standing up a spotter and a rescorer that have no terms to act on.
    private func vocabularyContext(_ bias: VocabularyBias,
                                   variant: CtcModelVariant) async -> CustomVocabularyContext? {
        guard let tokenizer = try? await CtcTokenizer.load(
            from: CtcModels.defaultCacheDirectory(for: variant)
        ) else {
            NSLog("[Parakeet] CTC tokenizer unavailable; custom vocabulary cannot be applied")
            return nil
        }
        let terms = bias.terms.compactMap { text -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(text)
            guard !ids.isEmpty else {
                NSLog("[Parakeet] vocabulary term \"\(text)\" did not tokenize; skipping it")
                return nil
            }
            return CustomVocabularyTerm(text: text, weight: nil, aliases: nil,
                                        tokenIds: nil, ctcTokenIds: ids)
        }
        guard !terms.isEmpty else { return nil }
        return CustomVocabularyContext(terms: terms)
    }

    /// Said's ISO code → FluidAudio's script-filter hint.
    ///
    /// **Written unqualified, deliberately.** `FluidAudio.Language` looks like the safe spelling and
    /// is not: the module also exports a `public struct FluidAudio`, and a type shadows a module
    /// name, so that reads as a nested type inside the struct and fails to resolve. (Exactly the
    /// same trap as `WhisperKit.WordTiming` — see `WhisperProvider`.) Nothing else in scope here
    /// declares a top-level `Language`, so the bare name is unambiguous.
    private func fluidLanguage(_ code: String?) -> Language? {
        guard let code else { return nil }
        return Language(rawValue: ParakeetLanguages.normalize(code))
    }

    // MARK: Batch transcription

    public func transcribe(samples: [Float], language: String?, bias: VocabularyBias?) async throws -> [TranscriptSegment] {
        lock.lock(); let mgr = manager; lock.unlock()
        guard let mgr else { throw CaptureError.engineNotReady }
        // FluidAudio throws `ASRError.invalidAudioData` below `minimumRequiredSamples` — 4 800
        // samples (0.3 s) at 16 kHz, verified at the pinned tag. Returning empty is the right
        // answer for a fragment that short anyway; letting it throw would fail a save over it.
        guard samples.count >= Self.minimumSamples else { return [] }

        // Said cuts the audio itself — see `chunkRanges`. Anything the model can take in one
        // inference (≤ 15 s) goes through as a single chunk, exactly as before.
        let ranges = samples.count <= ASRConstants.maxModelSamples
            ? [0..<samples.count] : Self.chunkRanges(samples)

        let chunks = ranges.compactMap { range -> (samples: [Float], offset: Double)? in
            guard range.count >= Self.minimumSamples else { return nil }   // a sub-0.3 s tail
            return (Array(samples[range]), Double(range.lowerBound) / 16_000)
        }
        let (words, texts) = try await decodeAll(chunks, primary: mgr, language: language, bias: bias)

        let duration = Double(samples.count) / 16_000
        guard !words.isEmpty else {
            return TranscriptAssembly.singleSegment(text: texts.joined(separator: " "), duration: duration)
        }
        let segs = TranscriptAssembly.segments(words: words)
        return segs.isEmpty
            ? TranscriptAssembly.singleSegment(text: texts.joined(separator: " "), duration: duration)
            : segs
    }

    static let minimumSamples = 4_800

    /// ONE inference over ≤ 15 s of audio with a FRESH decoder state, plus the vocabulary bias.
    private func decodeOne(_ chunk: [Float], manager mgr: AsrManager, language: String?,
                           bias: VocabularyBias?) async throws -> (words: [WordTiming], text: String) {
        var state = TdtDecoderState.make(decoderLayers: await mgr.decoderLayerCount)
        let result = try await mgr.transcribe(chunk, decoderState: &state, language: fluidLanguage(language))
        var words = Self.words(from: result)
        if let bias, !words.isEmpty {
            words = await applyVocabularyBias(bias, to: words, transcript: result.text,
                                              tokenTimings: result.tokenTimings ?? [], samples: chunk)
        }
        return (words, result.text)
    }

    /// Decode independent chunks in parallel, returning words and texts in CHUNK ORDER.
    ///
    /// Sequential decoding measured 2.6× slower than the vendor's chunker (RTFx 82 vs 214) purely
    /// because it runs four chunks at once. `AsrManager` is an actor, so parallelism means a pool
    /// of managers; they share the ONE loaded `AsrModels` (CoreML model references), so a clone
    /// costs its decoder scratch state and nothing else. Same size as the vendor's default pool.
    private func decodeAll(_ chunks: [(samples: [Float], offset: Double)], primary: AsrManager,
                           language: String?, bias: VocabularyBias?) async throws -> ([WordTiming], [String]) {
        guard !chunks.isEmpty else { return ([], []) }
        let workers = workerPool(primary: primary, count: min(Self.parallelism, chunks.count))
        var results = [(words: [WordTiming], text: String)?](repeating: nil, count: chunks.count)
        try await withThrowingTaskGroup(of: (Int, [WordTiming], String).self) { group in
            var next = 0
            func enqueue(_ i: Int, on worker: AsrManager) {
                let chunk = chunks[i]
                group.addTask {
                    let (w, t) = try await self.decodeOne(chunk.samples, manager: worker, language: language, bias: bias)
                    return (i, w.map {
                        WordTiming(text: $0.text, start: $0.start + chunk.offset, end: $0.end + chunk.offset,
                                   confidence: $0.confidence)
                    }, t)
                }
            }
            // One in-flight chunk per worker; each finished chunk hands its worker the next one.
            var workerOf: [Int: AsrManager] = [:]
            for w in workers where next < chunks.count { workerOf[next] = w; enqueue(next, on: w); next += 1 }
            while let (i, w, t) = try await group.next() {
                results[i] = (w, t)
                if next < chunks.count, let worker = workerOf[i] { workerOf[next] = worker; enqueue(next, on: worker); next += 1 }
            }
        }
        let done = results.compactMap { $0 }
        return (done.flatMap(\.words), done.map(\.text).filter { !$0.isEmpty })
    }

    static let parallelism = 4

    private func workerPool(primary: AsrManager, count: Int) -> [AsrManager] {
        lock.lock(); let loaded = models; lock.unlock()
        guard count > 1, let loaded else { return [primary] }
        return [primary] + (1..<count).map { _ in
            AsrManager(config: ASRConfig(tdtConfig: TdtConfig(boundarySearchFrames: 0)), models: loaded)
        }
    }

    // MARK: Said's own chunking

    /// Cut long audio into chunks the model takes in ONE inference, cutting at the quietest moment.
    ///
    /// **Why not FluidAudio's `ChunkProcessor`.** It decodes overlapping 15 s chunks and merges the
    /// token streams (an LCS + midpoint merger, plus the token dedup). Measured on a real lecture
    /// (2026-09-14): the merge dropped whole clauses at joins — "critical boundaries on our
    /// sampling distribution to create" → "quick to create", and a nine-word sentence gone
    /// outright — and toggling its `melChunkContext` merely moved WHICH clause was lost. Chunks
    /// that do not overlap have nothing to merge, and a cut placed in a pause costs nothing: the
    /// live path does exactly this and lost 0 of 486 words on the same audio.
    ///
    /// Each cut is the centre of the lowest-energy 200 ms probe in the last `searchBack` of the
    /// span — a pause when there is one, the least-bad instant when there is not — so no chunk
    /// exceeds `maxChunk` (14.5 s, half a second under the model's window). Energy is compared
    /// directly; there is no threshold to tune.
    static func chunkRanges(_ samples: [Float],
                            maxChunk: Int = 232_000,      // 14.5 s
                            searchBack: Int = 64_000,     // choose the cut within the last 4 s
                            probe: Int = 3_200,           // 200 ms
                            hop: Int = 800) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var pos = 0
        while samples.count - pos > maxChunk {
            let zoneStart = pos + maxChunk - searchBack
            let zoneEnd = pos + maxChunk
            var bestStart = zoneEnd - probe
            var bestEnergy = Float.greatestFiniteMagnitude
            var start = zoneStart
            while start + probe <= zoneEnd {
                var energy: Float = 0
                for i in start..<(start + probe) { energy += samples[i] * samples[i] }
                if energy < bestEnergy { bestEnergy = energy; bestStart = start }
                start += hop
            }
            let cut = bestStart + probe / 2
            out.append(pos..<cut)
            pos = cut
        }
        out.append(pos..<samples.count)
        return out
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
        guard let vocab = await vocabularyContext(bias, variant: ctc.variant) else { return words }
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

        // Same chunking as the in-memory path — the vendor's URL overload runs its own overlapping
        // chunk-joiner, which is exactly what `chunkRanges` exists to avoid. To keep a multi-hour
        // file from being resident in full, the file is read in ~10-minute blocks, each block is
        // cut with `chunkRanges`, and the last (possibly short) range is carried into the next block
        // so no cut ever lands on an arbitrary block edge.
        guard let file = try? AVAudioFile(forReading: url) else {
            // Not AVAudioFile-readable (some video containers): decode whole via AVAssetReader.
            let samples = try await AudioFileIO.decodeTo16kMono(url: url)
            return try await transcribe(samples: samples, language: language, bias: bias)
        }

        let resampler = Resampler16k()
        let fmt = file.processingFormat
        let blockFrames = AVAudioFrameCount(fmt.sampleRate * 600)   // ~10 min of source audio
        var carry: [Float] = []
        var origin = 0                     // 16 kHz sample index of carry[0]
        var words: [WordTiming] = []
        var texts: [String] = []

        func decode(_ ranges: [Range<Int>], in block: [Float]) async throws {
            let chunks = ranges.compactMap { range -> (samples: [Float], offset: Double)? in
                guard range.count >= Self.minimumSamples else { return nil }
                return (Array(block[range]), Double(origin + range.lowerBound) / 16_000)
            }
            let (w, t) = try await decodeAll(chunks, primary: mgr, language: language, bias: bias)
            words.append(contentsOf: w)
            texts.append(contentsOf: t)
        }

        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: blockFrames) else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            guard let fresh = resampler.resample(buf) else { continue }
            let block = carry + fresh
            let ranges = block.count <= ASRConstants.maxModelSamples ? [0..<block.count] : Self.chunkRanges(block)
            // Decode everything but the tail; the tail becomes the next block's head.
            try await decode(Array(ranges.dropLast()), in: block)
            let tail = ranges.last ?? (0..<0)
            carry = Array(block[tail])
            origin += tail.lowerBound
        }
        if !carry.isEmpty {
            try await decode(carry.count <= ASRConstants.maxModelSamples ? [0..<carry.count] : Self.chunkRanges(carry),
                             in: carry)
        }

        let duration = Double(file.length) / fmt.sampleRate
        guard !words.isEmpty else {
            return TranscriptAssembly.singleSegment(text: texts.joined(separator: " "), duration: duration)
        }
        let segs = TranscriptAssembly.segments(words: words)
        return segs.isEmpty
            ? TranscriptAssembly.singleSegment(text: texts.joined(separator: " "), duration: duration)
            : segs
    }

    /// `ASRResult`'s token timings folded into whole words. Empty when the engine reported none.
    static func words(from result: ASRResult) -> [WordTiming] {
        guard let timings = result.tokenTimings, !timings.isEmpty else { return [] }
        return TranscriptAssembly.words(fromTokens: timings.map {
            (text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence)
        })
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
        lock.lock(); let ready = manager != nil; lock.unlock()
        guard ready else { return nil }
        return ParakeetStream(provider: self, sink: sink, language: language, bias: bias, onUpdate: onUpdate)
    }
}

// MARK: - Parakeet's live stream

/// A rolling window over the BATCH path, not FluidAudio's `SlidingWindowAsrManager`.
///
/// **Why not the vendor's streaming manager.** It was the first implementation, and it was measured
/// on a real lecture (2026-09-14, `--selftest-stream --model parakeet`, 3 minutes, 486 words):
/// **131 words — 27% of the speech — never appeared live.** Whole windows came back empty because
/// the decoder state the manager carries between windows (its `timeJump` mechanism) periodically
/// skipped 6–8 s of audio; shrinking the window and switching off its false-positive token dedup
/// (which deleted eight words on a single-token match) only got that to 19%. None of it is
/// tunable from outside. Meanwhile the batch path — `transcribe(samples:)` with a FRESH decoder
/// state — produced 2 508 timed words for 2 508 spoken at 241× realtime on the same audio.
///
/// So this does what `StreamingTranscriber` already does for Whisper: about once a second,
/// re-transcribe everything since the last confirmed point with a fresh state, confirm the words
/// that are safely behind the trailing edge, and show the rest as the dimmed hypothesis. A 20 s
/// window costs ~80 ms per tick at 241×. The live words are therefore produced by the SAME code
/// that produces the saved transcript, which is also what makes the live save honest.
///
/// The pump-and-trim memory argument for the incremental reader still holds: the window is
/// bounded by `maxWindowSeconds`, so what is copied per tick is proportional to the window, never
/// to the session.
public actor ParakeetStream: TranscriptionStream {

    private let provider: ParakeetProvider
    private let sink: SampleSink
    private let language: String?
    private let bias: VocabularyBias?
    private let onUpdate: @Sendable (LiveTranscript) -> Void

    private var running = false
    private var lastSeenCount = 0
    /// Sample index where the next window begins — the end of the last confirmed word.
    private var windowStartSample = 0
    private var confirmedWords: [WordTiming] = []
    /// The unconfirmed tail of the latest window, so the live save on stop loses nothing.
    private var pendingWords: [WordTiming] = []

    /// Wait for at least this much fresh audio between ticks.
    static let tickSeconds: TimeInterval = 1.0
    /// Never confirm a word that ends within this of the window's live edge — the decoder is still
    /// changing its mind there (a word cut by the edge is the classic mistake).
    static let trailingSeconds: TimeInterval = 2.0
    /// Below this, confirm nothing: let a phrase form first.
    static let minConfirmSeconds: TimeInterval = 4.0
    /// Above this, confirm up to the trailing edge whether or not a good cut exists, so a run-on
    /// speaker cannot grow the window (and the per-tick decode) without bound.
    static let maxWindowSeconds: TimeInterval = 12.0
    /// A pause between words at least this long is a good place to cut.
    static let gapSeconds: TimeInterval = 0.3

    init(provider: ParakeetProvider, sink: SampleSink, language: String?, bias: VocabularyBias?,
         onUpdate: @escaping @Sendable (LiveTranscript) -> Void) {
        self.provider = provider
        self.sink = sink
        self.language = language
        self.bias = bias
        self.onUpdate = onUpdate
    }

    public func run() async {
        running = true
        while running {
            let (window, total) = sink.newSamples(after: windowStartSample)
            let fresh = Double(total - lastSeenCount) / 16_000
            guard fresh >= Self.tickSeconds else {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            lastSeenCount = total
            let offset = Double(windowStartSample) / 16_000
            let windowEnd = Double(total) / 16_000

            var words: [WordTiming] = []
            do {
                let segs = try await provider.transcribe(samples: window, language: language, bias: bias)
                guard running else { break }
                words = segs.flatMap { $0.words ?? [] }.map {
                    WordTiming(text: $0.text, start: $0.start + offset, end: $0.end + offset,
                               confidence: $0.confidence)
                }
            } catch {
                NSLog("[Parakeet] live window failed: \(error)")
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            apply(words, windowEnd: windowEnd, total: total)
        }
    }

    private func apply(_ words: [WordTiming], windowEnd: TimeInterval, total: Int) {
        let windowSeconds = windowEnd - Double(windowStartSample) / 16_000
        let edge = windowEnd - Self.trailingSeconds

        // Long silence: nothing to confirm, but do not let the window grow — advance past it.
        if words.isEmpty {
            if windowSeconds > Self.maxWindowSeconds {
                windowStartSample = max(windowStartSample, Int(edge * 16_000))
            }
            pendingWords = []
            onUpdate(LiveTranscript(confirmed: TranscriptAssembly.segments(words: confirmedWords), hypothesis: ""))
            return
        }

        // A forced cut lands at a word's END, and the next window then begins on that word's last
        // few milliseconds — enough for the decoder to re-emit it ("than than", "from from",
        // measured). If the window's first word starts on the window's edge and repeats the last
        // confirmed word, it is that echo, not speech.
        var words = words
        if let last = confirmedWords.last, let first = words.first,
           first.start - Double(windowStartSample) / 16_000 < 0.25,
           Self.bare(first.text) == Self.bare(last.text) {
            words.removeFirst()
            if words.isEmpty {
                pendingWords = []
                onUpdate(LiveTranscript(confirmed: TranscriptAssembly.segments(words: confirmedWords), hypothesis: ""))
                return
            }
        }

        var cut: Int? = nil   // index of the LAST word to confirm
        if windowSeconds >= Self.minConfirmSeconds,
           let lastBehindEdge = words.lastIndex(where: { $0.end <= edge }) {
            // Prefer a sentence end or a pause, searching back from the edge; otherwise, once the
            // window is long, take the edge itself.
            var i = lastBehindEdge
            while i >= 0 {
                let w = words[i]
                let endsSentence = w.text.last.map { ".!?。！？".contains($0) } ?? false
                let gapAfter = i + 1 < words.count ? words[i + 1].start - w.end : .infinity
                if endsSentence || gapAfter >= Self.gapSeconds { cut = i; break }
                i -= 1
            }
            if cut == nil, windowSeconds >= Self.maxWindowSeconds { cut = lastBehindEdge }
        }

        if let cut {
            let confirmed = Array(words[...cut])
            confirmedWords.append(contentsOf: confirmed)
            windowStartSample = min(total, Int(confirmed[cut].end * 16_000))
            pendingWords = Array(words[(cut + 1)...])
        } else {
            pendingWords = words
        }

        onUpdate(LiveTranscript(confirmed: TranscriptAssembly.segments(words: confirmedWords),
                                hypothesis: pendingWords.map(\.text).joined(separator: " ")))
    }

    private static func bare(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public func stop() {
        running = false
    }

    /// Everything transcribed so far — confirmed AND the unconfirmed tail of the last window. This
    /// is the live save on stop; the tail is real speech that never had a later tick to confirm it.
    public func snapshotSegments() -> [TranscriptSegment] {
        TranscriptAssembly.segments(words: confirmedWords + pendingWords)
    }
}
