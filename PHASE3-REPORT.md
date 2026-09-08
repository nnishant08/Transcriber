# Phase 3 — build report

`CLAUDE.md` records **decisions**. This records **findings**: what turned out to be true when the
code was read rather than assumed, what diverged from the build prompt, what was measured, and —
most importantly — what could not be.

---

## 0. Read this first: what this build was and was not able to do

**This phase was implemented in a Linux container with no Swift toolchain.** `swift`, `swiftc`,
`xcodebuild` and `codesign` are all absent; the machine is `x86_64 Ubuntu 24.04`. The project is a
macOS/iOS app that needs Xcode, Apple frameworks, Apple Silicon and CoreML.

The consequences are specific and none of them are hidden:

| Definition-of-done item | Status |
|---|---|
| `swift build -c release` green | **NOT RUN** — no toolchain |
| `Scripts/build_app.sh` produces a launching `Said.app` | **NOT RUN** |
| `Scripts/verify_ios_build.sh` green | **NOT RUN** — needs `xcodebuild` |
| `codesign -d -r-` unchanged | **NOT CAPTURED** — no `codesign`. Nothing in this phase touches `build_app.sh`, `setup_signing.sh`, the bundle id or the entitlements, so the requirement *should* be untouched; that is an argument, not a measurement. `Scripts/capture_baselines.sh` captures it on both sides. |
| `--selftest-doc` md5 unchanged | **NOT RUN.** Argued structurally in §6 below. |
| Pre-build Whisper fixtures committed | **TOOLING COMMITTED, FIXTURES NOT CAPTURED.** See §1. |
| Every pre-existing self-test passes | **NOT RUN** |
| New self-tests pass | **NOT RUN** — written, not executed |
| `--compare-engines` run over ≥10 real sessions | **NOT RUN.** Implemented; needs models, audio and a Mac. |
| Performance budgets measured | **NOT MEASURED.** §10 states what to measure and what to expect. |
| Model disk sizes reported | **NOT MEASURED.** §9 gives the download URLs to weigh. |

**Nothing in this report claims a test passed.** Where a guarantee is argued rather than measured,
it says so.

The compensating work actually done, since "I couldn't compile" is not on its own an engineering
position:

1. **Every third-party API was verified by reading the pinned source**, not from documentation — see
   §2, which is where the largest surprises were.
2. **Apple's `NLContextualEmbedding` API was verified against Apple's own documentation data**
   (their docs are a JS SPA; the underlying JSON endpoint has the declarations), so the one
   first-party API this phase newly depends on is not recalled from memory.
3. **A parallel verification pass** re-read the dependency at the pinned tag independently and found
   three real defects in the first draft, all fixed — see §3.
4. **An adversarial compile review** over every new and changed file found eleven more, all fixed —
   see §3a. Four of them would have shipped as *silent wrongness*: vocabulary biasing that did
   nothing while reporting success, live transcription windows dropped on the floor, a duplicate
   chunk written into the semantic index on every word-timed session, and one sentence split into
   two lines under the same speaker label. None would have produced an error or a log line.

**That the review found what it did is the strongest available argument that more remains.** Eleven
defects in code this carefully written, from one pass, means the compiler will find more. Treat the
first real build as part of the work, not a formality.

---

## 1. The baselines (§10.0)

`Scripts/capture_baselines.sh` is committed **in its own commit that touches no Swift**
(`a28a029`). That is the mechanism that makes the pre-build baseline still capturable after the
fact: check that commit out, build, run the script, and the tree is bit-for-bit pre-Phase-3.

```sh
git checkout a28a029
Scripts/build_app.sh && Scripts/capture_baselines.sh /tmp/baseline-before
git checkout claude/phase-3-transcription-core-8g38vc
Scripts/build_app.sh && Scripts/capture_baselines.sh /tmp/baseline-after
diff -ru /tmp/baseline-before /tmp/baseline-after
```

It captures: the `--selftest-doc` output and md5 (case 1 separately, so it stays comparable as case 2
grows), the Whisper transcription output for `--selftest` and `--selftest-stream`, the `codesign`
designated requirement, model disk usage, and `finalPass` wall clock + peak RSS.

**One nuance about the `SpeakerAlignment` fixture.** It can only be emitted by a Phase 3 binary
(`--selftest-align --emit-fixture <path>`), so it does NOT prove equivalence with the pre-Phase-3
build. It does not need to: `--selftest-align` asserts that equivalence *structurally*, by comparing
the dispatcher's output against `assignWholeSegment` — which IS the pre-Phase-3 function, preserved
unmodified. That check cannot drift, because it compares the code against itself. The fixture's job
is different and still worth having: it locks today's behaviour so a future change to
`assignWholeSegment` itself has something to fail against.

**One correction to the prompt's premise:** `--selftest-doc` does not print an md5 — it prints the
rendered markdown. The "case-1 md5" is the digest *of that output*, which the script now takes.

---

## 2. Dependency findings — the documentation is wrong, repeatedly

### 2.1 The ASR loading call (prompt §2, Warning 3) — RESOLVED

The prompt warned that the vendor's README, ASR guide and model card disagree, giving
`initialize(models:)`, `loadModels(_:)` and `configure(models:)`. **At v0.15.2 only
`loadModels(_ models: AsrModels) async throws` exists.** The other two are absent from `AsrManager`
entirely — `initialize` exists only on the *Diarizer* managers.

Worse than "the docs disagree": the vendor's own in-repo documentation calls functions that do not
exist. `Documentation/ASR/GettingStarted.md:38` calls `configure(models:)`;
`Documentation/API.md:188` documents `initialize(models:)`. Neither would compile.

### 2.2 `transcribe(_:source:)` does not exist

The prompt listed `transcribe(_ samples: [Float], source:) async throws -> ASRResult` as "verified
and safe to design against". It is not there. The real signature is:

```swift
public func transcribe(_ audioSamples: [Float],
                       decoderState: inout TdtDecoderState,
                       language: Language? = nil) async throws -> ASRResult
```

Two consequences the prompt's shape hides: the caller owns a **decoder state** it must construct
(`TdtDecoderState.make(decoderLayers: await mgr.decoderLayerCount)`), and `language:` is an **input
hint** for script-aware token filtering, not a selector. `source:` exists, but on
`SlidingWindowAsrManager.startStreaming(source:)` — a different type, a different purpose.

`Documentation/API.md:181-185` documents the non-existent overloads.

### 2.3 `ASRResult.tokenTimings` is real, and is the whole substrate

```swift
public struct TokenTiming: Codable, Sendable {
    public let token: String
    public let tokenId: Int
    public let startTime: TimeInterval   // seconds
    public let endTime: TimeInterval
    public let confidence: Float
}
```

Present on **both** the batch path and the streaming path, with no DTW and no second model. Wave 1
rests on this and it held up.

### 2.4 Parakeet has NO language identification — §5.2a option 1 is refuted by source

`ASRResult` exposes no detected language. `language:` is input-only. The prompt's first candidate
strategy — "determine whether `ASRResult` exposes a detected language; if it does, this is the
cheapest answer" — is settled in the negative by reading the struct.

The only Parakeet-family LID at this tag is
`StreamingNemotronMultilingualAsrManager.detectedLanguage() -> String?`, which belongs to a
*different model* (Nemotron multilingual streaming), and adopting it would mean shipping a third ASR
model to answer a question Whisper already answers. Not taken. See §4 for what was done instead.

### 2.5 Offline mode EXISTS at the pin, under another name — §10.2 corrected

The prompt asked for `ModelHub.offlineMode`. `ModelHub` does not exist at v0.15.2; it lands at
**v0.15.5**, in the same change that **deletes `DownloadUtils`**. But the capability is already there
at the pin, spelled differently:

```swift
nonisolated(unsafe) public static var DownloadUtils.enforceOffline: Bool = false
public enum DownloadUtils.OfflineError: LocalizedError {
    case networkDisabled(operation: String)
    case modelMissing(repo: ..., missing: ...)
}
```

`ModelGate.neverDownloadModels` now sets it, *and* keeps Said's own gate — because the library flag
covers FluidAudio only and **WhisperKit has no offline flag at any version**, and because a library
throwing from inside a download routine cannot produce a message like "pick a model you already
have".

### 2.6 The FluidAudio pin: HELD at 0.15.2

The prompt's Warning 1 is confirmed: the repo's `README`, `FluidAudio.podspec` and `CITATION.cff`
all still say `0.12.4`; `git ls-remote --tags` runs to `v0.15.6`. The pin was not "fixed" downward.

**Decision: stay at 0.15.2.** Everything Phase 3 needs is present — `AsrManager`,
`AsrModels.downloadAndLoad(version:)`, `tokenTimings`, `SlidingWindowAsrManager` with its
confirmed/volatile split, `configureVocabularyBoosting`, `TimedSpeakerSegment.embedding`,
`enforceOffline`. Bumping to ≥0.15.5 removes `DownloadUtils`, which breaks
`AsrModels.download(progressHandler: DownloadUtils.ProgressHandler?)` **and** the diarizer's download
plumbing — a breaking change across two subsystems, in a build that cannot be compiled here. The
`ModelHub` migration is a defined, separate piece of work, not a side effect of this phase.

### 2.7 WhisperKit 1.0.0 → 1.1.0: bumped, and here is exactly what changed

Both tags are `v`-prefixed (`v1.0.0`, `v1.1.0`); SPM's `exact: "1.1.0"` resolves it.

**Every API Said uses is source-compatible.** `WhisperKitConfig(model:modelFolder:load:download:)`,
`WhisperKit.download(variant:progressCallback:)`, `transcribe(audioArray:decodeOptions:)`,
`detectLangauge(audioArray:)` [sic — still misspelled], `WhisperKit.sampleRate`, all `DecodingOptions`
fields and all `TranscriptionSegment` properties are unchanged.

Two real changes:

1. **`AudioInputConfig` → `AudioInputOptions`**, with `WhisperKitConfig.audioInputConfig`
   deprecated. Said never referenced that symbol, so it does not bite — but it proves the release is
   not purely additive.
2. **`transcribe(audioPath:)` gained a defaulted `audioInputOptions:` inserted BEFORE
   `decodeOptions:`.** A labelled call still compiles.

**The headline benefit is real but OPT-IN, and narrower than the prompt implies.**
`AudioLoadingMode` defaults to `.fullFile`; bounded-memory chunked reading requires passing
`AudioInputOptions(audioLoadingMode: .incremental)`, and it exists on the **`audioPath:` overload
only**. `TranscriptionEngine.transcribeFile` now asks for it explicitly.

**Follow-up not taken:** `Importer` decodes files to `[Float]` first and then calls the in-memory
array path, so **imports do not benefit from the incremental reader**. Routing imports through the
file path would get them the memory win, but it changes the import pipeline's behaviour (its own
decode, its own resampling, its own language detection on the decoded lead-in) and was out of scope.
It is the single highest-value follow-up for long-lecture imports.

### 2.8 A process note worth recording

Midway through, a background agent ran `git checkout` in the shared FluidAudio clone and moved it to
**v0.15.6**, silently invalidating reads taken from the working tree. Every load-bearing fact was
subsequently re-verified in an isolated `git worktree` pinned to `7f963cd` (v0.15.2), and all of them
held. If this build is ever repeated: **use a dedicated worktree per tag**, not a shared checkout.

---

## 3. Defects found by the independent verification pass

A second, independent read of the pinned tag found three real defects in the first draft. All fixed
(`fc65e76`).

1. **Vocabulary biasing was only on the LIVE path.** `AsrManager` has *no* vocabulary API; the only
   wired-up biasing is on `SlidingWindowAsrManager`. Live text is transient — the **batch** pass
   produces the transcript that is saved, searched, exported and summarised. Shipping as drafted
   would have meant the vertical packs appearing to work while every saved transcript came out
   unbiased: exactly the "packs silently inert" outcome §5.4 says to stop the build over. The batch
   path now composes `CtcKeywordSpotter` → `VocabularyRescorer` → `ctcTokenRescore` by hand, in the
   same order and with the same size-aware config the streaming manager uses internally.
2. **Three languages were routed to Parakeet that it may not support.** The routing table was built
   from FluidAudio's `Language` enum (28 codes), which is three more than the model card's 25: `be`,
   `bs`, `sr`. That enum is a **script filter** — which alphabets the decoder can constrain itself
   to — a strict superset of what the model was trained to transcribe. Routing Belarusian to Parakeet
   because the Cyrillic filter accepts it is precisely the failure the router exists to prevent.
3. **The Parakeet minimum-sample guard was wrong.** It was 1 600 samples; FluidAudio throws
   `ASRError.invalidAudioData` below `minimumRequiredSamples` = **4 800** (0.3 s). A 0.2 s buffer
   would have thrown inside a save.

---

## 3a. Defects found by the adversarial compile review

A second fleet re-read every new and changed file against the pinned dependency sources, hunting
compile errors and logic bugs — the job a compiler would have done. It found **eleven** real defects.
Four of them would have shipped as silent wrongness, which is the category that matters, and three
were hard compile errors that would have stopped the build dead.

1. **`WhisperKit.WordTiming` does not resolve** — a compile error. The module exports an
   `open class WhisperKit`, and **a type shadows a module name**, so the qualified spelling reads as
   a nested type inside the class. Fixed by inference; only `SaidKit.WordTiming` is spelled out
   (safe, since nothing shadows `SaidKit`).
2. **The same trap in `FluidAudio.Language`** — the module exports a `public struct FluidAudio`
   whose own source comment calls it a "namespace collision". Found by the reviewer *and*
   independently while sweeping for the first one.
3. **Vocabulary terms were never tokenized — biasing was a complete no-op that reported success.**
   See §5; this is the most important finding in the build.
4. **Live windows were permanently dropped.** `SlidingWindowAsrManager` emits each window exactly
   once and never revises it; `isConfirmed` describes whether *that* window cleared the confidence
   bar, not a promise to re-send. Discarding the words of an unconfirmed update therefore lost that
   speech for good. The vendor's own `updateTranscriptionState` promotes the PREVIOUS volatile text
   on a confirmed window; `ParakeetStream` now mirrors that, and `snapshotSegments` includes the
   trailing pending window — otherwise every session was silently truncated by up to one window.
5. **A `CancellationError` poisoned the Whisper word-timestamp path.** The catch around the
   word-timestamp pass was unconditional, so stopping a recording would mark the model as unable to
   produce word timings for the rest of the app run *and* pay for a second full transcription pass on
   the way out. Cancellation now rethrows.

6. **`SpeakerOperations.cosineDistance` does not exist** — a compile error that would have taken
   the whole of SaidKit with it. In FluidAudio 0.15.2 the FILE is `SpeakerOperations.swift` but the
   TYPE inside it is `public enum SpeakerUtilities`; the identifier `SpeakerOperations` appears
   nowhere in the dependency's sources. **This is the third variant of one root cause — a name read
   off the wrong axis.** Findings 1 and 2 read a type name off a MODULE name; this one read it off a
   FILE name. All three are invisible without a compiler and all three were found by reading the
   dependency's actual declarations.
7. **`snippets.contains(\.isSlide)`** — a compile error. The unlabelled `contains(_:)` is the
   `Element: Equatable` overload; `SearchSnippet` is deliberately not Equatable, and a key path is
   not an element. Needed `contains(where:)`.
8. **The semantic chunker emitted a duplicate tail chunk on every word-timed session.** The
   "already covered" guard compared raw SEGMENT bounds against a chunk end derived from the last
   WORD — which is strictly earlier whenever word timings exist — so it reported "not covered" for
   precisely the segments it had just written. Invisible on legacy sessions, universal on Parakeet
   ones: the index stored duplicate vectors for the same passage and search spent its budget
   returning it twice. Fixed by tracking whether a segment actually arrived since the last flush,
   which is what the guard was trying to ask.
9. **Absorbing a stray word left a scar.** `absorbShortRuns` merged a one-word excursion into a
   neighbour but never coalesced the two same-speaker runs it left adjacent, so `A A A A A B A A A A A`
   came back as *two* runs of A — and the caller, seeing `runs.count > 1`, split one sentence into two
   consecutive lines under the same speaker label. That is the exact artefact absorption exists to
   remove. The pre-existing self-test could not catch it: its only short run sat at the END, where the
   merge collapses to a single run either way.
10. **Slide grouping did not group.** Jaccard at 0.75 divides by the UNION, so it charges a reading
    for every word the other reading happened to pick up — and the penalty is worst on SHORT slides,
    which are exactly the titles and section dividers most likely to stay up longest. One plural
    misread on a five-word title scores 0.67 and starts a new slide. The committed
    `--selftest-slides` fixture (six frames, three real slides) would have produced **five** spans and
    failed every assertion in it. Switched to the **overlap coefficient** (intersection over the
    SMALLER set) with a `minimumSizeRatio` guard: the coefficient asks "is one reading essentially
    contained in the other?", and the guard closes the failure it opens — a short reading being
    swallowed by a long unrelated one. Both directions are now asserted.
11. **A split dropped any character before the first word.** `assignByWord` anchored the FIRST part on
    its first word rather than on the start of the string, so a leading dash, quote or bracket — a
    character the engine never emitted as a token — vanished from the saved transcript. The tail was
    already anchored at `endIndex` for exactly this reason; the head simply was not treated
    symmetrically.

Plus a data race (`wordTimestampsUnsupported` read outside the lock that guards its mutation) and a
misplaced `ModelGate.syncToDependencies()` call that had landed inside a `didSet` instead of the
launch path — where it actually matters, because a `didSet` does not fire on initialisation.

**What the review changed about the self-tests.** Five of these eleven are logic bugs that a green
build would still have shipped, and in three cases the suite ran straight past them. So each fix
landed with the assertion that would have caught it: the chunker now asserts every chunk reaches
further than the one before it and that none is contained in its predecessor; alignment asserts a
stray word MID-sentence (not at the end) does not split the line, and that a leading character
survives a split; slide grouping asserts both the case the new metric closes (a plural misread) and
the one it opens (a short reading inside a long one). **A fix without the test that would have caught
it is half a fix**, and on this build — where nothing can be compiled — it is less than half.

## 4. §5.2a — the language-detection chicken-and-egg, resolved

The problem is real: if Parakeet is primary you cannot detect the language with Whisper without
loading Whisper, which is what you were avoiding.

**None of the prompt's three options was adopted as stated.** What shipped:

- **The common case has no chicken-and-egg at all.** The language setting defaults to an *explicit*
  `"en"`, and the picker offers explicit codes. For every session with an explicit language the
  router has the language before recording starts. Only **Auto** needs detection.
- **Auto uses option 3** (Whisper as the detector) — but it falls out of the routing rule rather than
  being a special case. `startFlow` resolves the language *first*; a `nil` language routes to
  Whisper by `EngineRouter`'s own rule; Whisper is also the only engine that can detect; after
  detect-once-then-pin, the router runs again and swaps to Parakeet if the detected language is
  covered. Cost: on Auto sessions only, a Whisper load and possibly a Parakeet load.
- **Option 1 is refuted by source** (§2.4).
- **Option 2 (`NLLanguageRecognizer` over Parakeet's output) was NOT adopted as a router**, because I
  could not test it here and §5.2a explicitly warns against shipping an untested heuristic as the
  default. Its place in a future build is as a **post-hoc detector of the failure**, not a router: it
  can flag "this may have been recorded in Hindi — re-transcribe with Whisper?" where it can only
  prompt, never silently redirect. That is where an untested heuristic belongs. **Not built.**

**The failure mode is handled as §5.2a requires:** one action, **Viewer ▸ Re-transcribe…**, with the
engine picker and the edits-will-be-orphaned warning.

**Untested:** whether Whisper's detector is accurate enough on real Hindi/Arabic/Vietnamese audio to
route correctly. Smoke-test item 4.

---

## 5. §5.4 — does vocabulary biasing work on Parakeet?

**The mechanism exists, is public, and is now correctly wired on both paths. Whether it measurably
improves recognition is UNVERIFIED, because it needs models and audio.** `--selftest-bias` is the
test; it prints the exact `say`/`afconvert` commands to make a fixture.

> **It was wired and INERT in the first draft, and nothing about the code said so.** Terms were built
> as `CustomVocabularyTerm(text:)`, leaving both `tokenIds` and `ctcTokenIds` nil. Both rescoring
> paths do `let vocabTokens = term.ctcTokenIds ?? term.tokenIds` followed by
> `guard let vocabTokens, !vocabTokens.isEmpty else { continue }` — so **every term was skipped**,
> the rescorer found nothing to do, and custom vocabulary and the vertical packs did nothing at all.
> The transcript came out fine; it was simply unbiased, and no log line, no error and no API result
> would have said otherwise.
>
> This is the exact failure §5.4 exists to prevent, and it is worth dwelling on *how* it hid: the
> initializer is public, takes the obvious argument, and compiles. The tell was only visible by
> reading the consumer. Terms are now tokenized with `CtcTokenizer` before the context is built,
> mirroring the vendor's `loadWithCtcTokens` — which, tellingly, is the only place in their entire
> tree that builds a usable context.
>
> **Smoke-test item 2 is therefore not optional.** It is the only thing that can distinguish "wired
> correctly" from "wired and inert" for real.

What was established by reading the source:

- It is **post-hoc CTC rescoring, not decode-time biasing**. Parakeet TDT decodes normally; then a
  CTC keyword spotter's log-probability matrix is used to ask, per word, whether a vocabulary term
  scores better acoustically than what TDT emitted, with a context-biasing weight added. Words are
  replaced only when the term wins.
- It costs a **second CoreML model** (`parakeet-ctc-110m-coreml`, a separate download) and a
  **second encoder pass over the audio**. Said loads it lazily and only when a vocabulary is actually
  in play.
- **`CustomVocabularyContext.minTermLength` defaults to 3, and shorter terms are dropped by the
  library** — following the NeMo CTC-WS finding that very short terms cause more false substitutions
  than corrections. **A two-letter acronym in a vertical pack will not bias Parakeet.** Said keeps
  the library default: a spurious "VR" every time someone says "or" is a worse transcript than a
  missed boost. This is a real, user-visible limitation and belongs in the user guide.
- BK-tree fuzzy matching is compiled off at this tag (`useBkTree = false`).
- A failure anywhere in this chain degrades to the **unbiased** transcript. It can never fail a save.

**If `--selftest-bias` shows no effect on real audio, that is a stop-the-build finding** and the
honest response is to ship `.whisper` as the default `EnginePreference` until it is fixed — a
one-line change, deliberately.

---

## 6. What must not have moved, and why I believe it did not

`--selftest-doc`'s md5 could not be run. The structural argument:

- `DocumentBuilder.markdown(meta:segments:frames:)` was **not modified**. Confirm with
  `git diff 1f322f1..HEAD -- Sources/SaidKit/DocumentBuilder.swift` — the changes are `WordTiming`,
  `TranscriptSegment`'s coding, `SessionMeta`'s new optional fields, `SessionDoc.slides`, and the
  slide-cache refresh in `writeSession`. None is on the markdown path.
- Word timings are a `session.json`-only addition, encoded **only when non-empty**, with an explicit
  `encode(to:)` — the synthesized `encodeIfPresent` would have written `"words":[]` and dirtied every
  session, which is why the coding is hand-written.
- `slides` is derived and encoded only when non-empty; a session with no frames gains no key.
- `SessionMeta`'s new fields are optional with synthesized `encodeIfPresent`.

**Search ranking** is the other thing that could have moved silently. It does not: `SearchIndex`
stores the per-FRAME slide counts as well as the per-span ones, so speech frequency is recovered by
**exact subtraction** rather than by re-tokenising a different string. A session with no frames has
both tables empty, so `weighted` collapses to `Double(matchCount)` and the score is bit-for-bit what
it was.

**Speaker alignment on legacy sessions** is guaranteed structurally rather than by fixture: a segment
with no word timings is routed to `assignWholeSegment`, which *is* the pre-Phase-3 function,
unmodified. `--selftest-align` asserts the dispatcher and that function agree element-for-element.

---

## 7. Three tuned constants, three justifications

| Constant | Value | Why, and how confident |
|---|---|---|
| `VoiceprintMatcher.maxDistance` | **0.45** cosine distance | Measured in the same units FluidAudio clusters in (`SpeakerOperations.cosineDistance`), so directly comparable to the diarizer's own `clusteringThreshold` of 0.7 — and deliberately far tighter. Cross-session matching holds neither mic nor room fixed, and the costs are wildly asymmetric: a miss costs one click, a false merge silently attributes one person's words to another. WeSpeaker same-speaker pairs typically sit at 0.1–0.4 and different-speaker at 0.7–1.0; 0.45 is inside that gap, on the safe side. **Reasoned from the literature, not measured on real data.** Wants tuning against real multi-session recordings. |
| `SlideSegmenter.similarityThreshold` | **0.75** Jaccard over OCR word sets | The same static slide read twice by Vision typically agrees on >90% of words; a real slide change usually shares only stock words and lands well below half. 0.75 sits in the empty middle, biased toward NOT collapsing — wrongly splitting one slide costs a duplicate card, wrongly merging two costs a slide that vanishes from the timeline. **Reasoned, not measured.** |
| `SpeakerAlignment.minimumRunWords` | **3** | Diarizer boundaries are not exact, so the word or two either side of a real turn change is routinely misattributed. Splitting on one stray word would manufacture a one-word "Speaker 2:" line inside someone else's sentence far more often than it would catch a real interruption. Three words is about the shortest real turn ("no, that's wrong"). **Reasoned, not measured.** |
| `SearchIndex.slideMatchWeight` | **0.35** | Slide text is denser and noisier than speech; weighting equally lets a slide-heavy session outrank one where the topic was actually discussed. Not near zero, because a phrase that appeared *only* on a slide must still surface — that is the capability Wave 5 exists for. |
| `HybridRetrieval.rrfK` | **60** | The original RRF paper's value and the de-facto default. Chosen over a weighted score blend deliberately: the two scores are not comparable (unbounded match counts vs cosine similarities in [-1,1]), and normalising them into agreement is exactly the tuning that produces a hybrid ranker *worse* than the keyword search it replaced. Rank fusion needs no calibration. |

---

## 8. The embedding model (§9.2) — a deliberate divergence

**Shipped: Apple's `NLContextualEmbedding`, not a pinned third-party CoreML model.**

The prompt named multilingual-e5-small and EmbeddingGemma-300m, and dismissed Apple's options in one
line: "`NLEmbedding` is word-level with no context, `NLContextualEmbedding` is token-level and needs
you to own the pooling, and `FoundationModels` exposes no embedding API at all".

Two of those three are correct and one is a different API:

- **`FoundationModels` exposes no embedding API** — verified. It is a generation model.
- **`NLEmbedding` really is inadequate** — word-level, no context.
- **`NLContextualEmbedding` is a different thing**, and the objection to it is that you must
  mean-pool the token vectors yourself. That is about fifteen lines (`meanPooled`).

Weighed against what it buys:

- **macOS 14 / iOS 17** — exactly Said's deployment floor, verified against Apple's documentation
  data.
- **Contextual and multilingual**, which is the actual requirement for an app that transcribes 25+
  languages.
- **Assets come from the OS**, not HuggingFace. The "no account, nothing leaves the device" story
  needs no new model repo to pin, host, verify and keep alive — and `requestAssets()` is exactly the
  "explicit model download the user consents to" §9.3 asks for.
- **No disk footprint Said owns**, in a phase that already doubles the model directory.

And the decisive practical point: **I could not verify that any specific CoreML conversion of
e5-small exists at a pinnable repo + revision.** Shipping an unverifiable third-party asset would
have been the weaker engineering position, not the stronger one.

`EmbeddingProvider` is a seam precisely so this is reversible on evidence. If the golden query set
(§9.4) shows a pinned e5-small beating it, that is a new provider and nothing else changes.

**The golden-query-set gate is NOT satisfied** — the set does not exist (only the user can write
it), so semantic search **ships OFF by default**, which is what §9.4 requires when the gate has not
been met.

**Honest cost, as §9.4 asks it be stated:** this wave takes on an index lifecycle Said owns forever —
re-embedding on edit, on cleanup, on re-transcription, and on every schema change. All four are
wired. A badly weighted hybrid ranker is *worse* than pure keyword, which is why RRF was chosen over
a tunable blend.

---

## 9. Model disk footprint (§10.2a) — NOT MEASURED

`Settings ▸ Storage` is built and reports real per-model sizes by walking the two cache roots, both
source-verified:

- WhisperKit: `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<variant>/`
- FluidAudio: `~/Library/Application Support/FluidAudio/Models/<repo folder>/`

It **discovers rather than predicts** — it enumerates what is there, so a variant Said has never
heard of still shows up and can still be deleted.

**No sizes are reported here because nothing could be downloaded or weighed.** The repos to weigh:

| Model | HuggingFace repo | Needed when |
|---|---|---|
| Parakeet v3 | `FluidInference/parakeet-tdt-0.6b-v3-coreml` | default engine |
| Parakeet v2 | `FluidInference/parakeet-tdt-0.6b-v2-coreml` | not shipped by default |
| CTC spotter | `FluidInference/parakeet-ctc-110m-coreml` | **only** when custom vocabulary or a pack is active |
| Diarizer | `FluidInference/speaker-diarization-coreml` | speakers on |
| Whisper | `argmaxinc/whisperkit-coreml` | long-tail languages, and the Auto detector |

**Parakeet is not auto-downloaded on upgrade**, as §10.2a requires: `EngineRouter` only routes to an
engine that `isInstalled`, so an existing user who has never fetched Parakeet keeps using Whisper
until they choose otherwise.

**No HuggingFace token or account is needed** — verified at the pinned tag: `DownloadUtils` attaches a
`Bearer` header *only* when an `HF_TOKEN`-style environment variable exists. The positioning holds.

---

## 10. Performance (§10.3) — NOT MEASURED, but one defect is structurally fixed

| Metric | Target | Status |
|---|---|---|
| Live streaming memory over 2 h | bounded | **Structurally fixed, not measured.** See below. |
| `finalPass` wall clock, 90 min | < 60 s | Not measured. Parakeet's RTFx should make this comfortable. |
| Stop → openable session | no worse | Not measured. |
| Semantic index, 100 sessions | reported, off-main, cancellable | Off-main and cancellable are implemented; not measured. |
| Voiceprint match per session | < 2 s | Not measured. It is a cosine scan over ≤12 vectors per stored voice. |

**The §5.3 defect, precisely.** `StreamingTranscriber` re-`snapshot()`s the entire growing sample
buffer roughly once a second. Swift arrays are copy-on-write, so the copy is *not* paid at the
`snapshot()` — it is paid on the very next `append`, which finds the buffer shared and duplicates all
of it. At 16 kHz Float32 a two-hour session is ~460 MB, so that is a ~460 MB memcpy per second,
growing linearly with session length, on the audio callback's path.

The fix is structural rather than incremental: `SlidingWindowAsrManager` buffers internally and
**trims what it has consumed**, bounded to `left + chunk + right` seconds regardless of session
length. `ParakeetStream` reads only what is new via `SampleSink.newSamples(after:)`. Live memory is
therefore flat in session length **on the Parakeet path**.

**The Whisper streamer keeps its old behaviour, deliberately.** Whisper's decoder has no incremental
entry point — `transcribe(audioArray:)` takes a whole array — so there is no half-fix available.
What changed is which engine is *default*. `SampleSink.largestIncrementalRead` is instrumented so
`--selftest-stream` can assert the incremental reader never hands back more than one window.

---

## 11. Crash recovery (§10.2c) — the prompt's premise is FALSE

§10.2c says: *"Said recovers from a crash or kill via incremental audio writes, with the session
recovered on next launch. Confirm the recovery path still works after the streaming rewrite."*

**No such mechanism exists in this codebase, and none did before Phase 3.** Verified by searching the
whole tree for crash/recovery/incremental-write machinery: the only hits are *capture* recovery
(rebuilding a dead audio device mid-session), which is a different feature.

Audio is written **once, at stop**, in `AppModel.finalizeDocumentSession`
(`Sources/Said/AppModel.swift`), from the in-memory `SampleSink` buffer:

```swift
let buffer = engine.sink.snapshot()
if saveAudioEnabled, buffer.count > 1_600 {
    audioName = (try? AudioFileIO.writeCompactAudio(buffer, to: dir.appendingPathComponent("audio.m4a")))?...
}
```

**A `kill -9` mid-recording loses the entire session — audio and transcript.** Smoke-test item 14
would fail today, and would have failed before this phase.

I have **not built it**, because it is a substantial feature (an incremental audio journal plus
launch-time session recovery) that no wave scoped, and scaling the work up unasked is not my call.
What §10.2c *can* be answered on: the streaming rewrite introduced **no coupling** between the
incremental read and the audio write path — `newSamples(after:)` is a separate reader that mutates
nothing, and `snapshot()` is untouched. Those two are independent, as required.

**Recommended as the highest-priority follow-up.** The sink is currently the *only* copy of a
session's audio, which also means memory grows linearly with session length regardless of engine —
a periodic incremental flush would fix the durability gap and that growth together.

---

## 12. `.said` compatibility (§10.2b)

**`formatVersion` stays 1.** Adding `edits.json` and new optional `session.json` keys changes the
archive's *contents*, not its *structure*. A Phase-2 build opening a Phase-3 bundle installs
`edits.json` into the session folder and ignores it, and ignores unknown `session.json` keys because
every one is `decodeIfPresent` — **degradation, not corruption**. Bumping the version would make old
builds *refuse* the file, which is strictly worse. A Phase-2 bundle opens in this build unchanged.

**Not verified by actually opening a Phase-3 bundle in a Phase-2 build** — that needs two builds.

**One import-path subtlety worth its own note.** `SessionBundle` stages a session folder's *entire*
contents rather than an allow-list. That is what makes `edits.json` round-trip for free — and it is
also why the voiceprint file must never land inside a session folder: it would then be re-exported in
every future `.said` of that session, silently, with no opt-in. So `installPayload` explicitly skips
`voiceprints.json` and hands it to `VoiceprintStore.stagePending` for the user to accept or discard.

---

## 13. Divergences from the build prompt, collected

| § | Prompt asked | Shipped | Why |
|---|---|---|---|
| 4.2 | New `SessionDoc.schemaVersion`, `?? 1`, this build writes 2 | Reused `SessionMeta.schemaVersion` (already existed at 2), bumped to **3** | A document with two disagreeing version numbers is worse than one that moves. The repo wins. |
| 4.6 | Assert a v1 `session.json` round-trips without gaining `schemaVersion` | Assert it round-trips **at its own version** (0) and gains no `words` key | The repo has always written `schemaVersion` unconditionally. The invariant that matters — a read must not silently upgrade a session — is asserted instead, and is stronger. |
| 5.2a | Pick one of three detection strategies | Explicit language needs none; Auto uses Whisper, falling out of the routing rule | See §4. |
| 9.2 | Pin a third-party CoreML embedding model | Apple `NLContextualEmbedding` behind a provider seam | See §8. |
| 10.2 | `ModelHub.offlineMode` | `ModelGate` + `DownloadUtils.enforceOffline` | `ModelHub` does not exist at the pin; the gate covers WhisperKit too. See §2.5. |
| 10.2c | Confirm crash recovery still works | Reported that it does not exist | See §11. |
| 2 | `transcribe(_:source:)`, `initialize(models:)` | The real signatures | See §2.1–2.2. |

---

## 14. What I was asked to do and could not

Stated plainly rather than quietly omitted:

1. **Build, run or test anything.** No Swift toolchain. Everything in §0's table.
2. **Capture the pre-build baselines.** The tooling is committed in a no-Swift commit so they can
   still be captured; they have not been.
3. **Run `--compare-engines` over ten real sessions.** Implemented, never executed. **The decision to
   make Parakeet the default is therefore still resting on other people's benchmarks** — exactly the
   situation §5.8 exists to end. Run it before shipping.
4. **Demonstrate that vocabulary biasing works on Parakeet.** The mechanism is wired on both paths
   and was read line by line; whether it measurably corrects a term is unverified. §5.
5. **Measure model disk sizes or any performance budget.** §9, §10.
6. **Tune three constants against real data.** §7 gives the reasoning and says which are guesses.
7. **Build the golden query set** (only the user can) — so semantic search ships OFF, as required.
8. **Build crash recovery**, which the prompt assumed already existed. §11.
9. **Any iOS UI work.** §10.4 asks to "budget for the UI work on the phone in the same pass". Not
   done: every Phase 3 capability is in `SaidKit` and reaches iOS through it, but the touch
   affordances for editing and voiceprint confirmation are macOS-only. The iOS app is a separate
   target that this phase did not open. **This is the largest single omission.**

---

## 15. What to do first, on a Mac

1. `git checkout a28a029 && Scripts/build_app.sh && Scripts/capture_baselines.sh /tmp/baseline-before`
2. `git checkout claude/phase-3-transcription-core-8g38vc && Scripts/build_app.sh` — **expect compile
   errors and fix them**; nothing here has been through a compiler.
3. `Scripts/verify_selftests.sh` — the six pure Phase 3 modes should pass without any model.
4. `Scripts/capture_baselines.sh /tmp/baseline-after && diff -ru /tmp/baseline-before /tmp/baseline-after`
   — the `--selftest-doc` md5 and the codesign requirement must be identical; the Whisper transcript
   text may differ only if you changed the model.
5. Assemble the terms file and run `--compare-engines`. **Then** decide whether Parakeet ships as the
   default.
6. Work the smoke-test checklist in `CLAUDE.md`.
