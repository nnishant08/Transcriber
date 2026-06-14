# Transcriber — Stage 1 Build Prompt
### Speaker Diarization · Multilingual Transcription · Calendar-Aware Bot-Free Capture · Transcript Cleanup & Custom Summary Modes

> Paste this whole file into Claude Code at the repo root. It is one pass. The **only** acceptable pause point is when a macOS permission must be granted by a human (Calendar). Do not stop for design questions, do not deliver in stages, do not ask for confirmation between features — build the whole thing, keep the build green, run the self-tests, then hand back the human smoke-test checklist.

---

## 0. Prime directives (read before touching anything)

You are extending **Transcriber**, a shipping, fully on-device macOS transcription app (Apple Silicon, macOS 13+ deployment, built & run on macOS 26; SwiftUI + AppKit + SPM). Read `CLAUDE.md` end-to-end first — it is the source of truth for the architecture, the pinned dependency API facts, the signing model, and the self-test harness. Everything below assumes that context.

**The moat is "everything stays on this Mac — no cloud, no account, works offline."** Every one of the four features in this build preserves that. No feature may add a network call that sends user content off-device, require an account, or require an API token. On-device model downloads (one-time, anonymous, then offline) are the only acceptable network use, exactly like WhisperKit's model download today.

**Four features, all additive, all OFF or neutral by default:**
- **A — On-device speaker diarization** ("who spoke when") + per-session speaker renaming. New dependency: **FluidAudio**.
- **B — Multilingual transcription** (lift the "English-first" pin). No new dependency — unlock WhisperKit's existing multilingual capability.
- **C — Calendar-aware, bot-free auto-capture.** New optional permission: **Calendar (EventKit)**.
- **D — Transcript cleanup (filler/punctuation) + user-authored custom summary modes.** No new dependency — reuse FoundationModels.

**Non-negotiable non-regression rules (these govern every decision):**
1. **Do not touch** the capture layer, the streaming algorithm, `finalPass()`, the global hotkeys, the code-signing flow, or the visual-capture stream topology, except where this prompt explicitly says to. The `AudioCaptureMic` / `AudioCaptureSystem` / `Resampler16k` / `SampleSink` / `StreamingTranscriber` data path stays byte-for-byte intact for existing flows.
2. **Default behavior must be byte-identical to today.** With all four toggles in their default state (English, no diarization, no cleanup, no calendar), a recorded session must produce the exact same `transcript.md` and a semantically identical `session.json` as the current build. Prove this with the existing self-tests (they must all still pass unchanged) plus the diff checks specified per feature.
3. **`transcript.md` stays the verbatim canonical record.** Diarization adds speaker labels; cleanup is stored *separately* and is opt-in to view. Neither may overwrite or lose the verbatim text or the `[mm:ss]` timestamps.
4. **`session.json` stays backward-compatible.** Every new field is `decodeIfPresent` / optional with a sane default. Old-schema `session.json` files (including the already-migrated legacy sessions) must continue to decode and open in the Library and Session Viewer. No new on-disk migration of existing folders is required for this build — old sessions simply have no speaker/cleanup/custom-mode data, which renders cleanly.
5. **Heavy work runs OFF the save path.** Diarization and cleanup are post-processing passes that run like the existing on-device titling does (`Task.detached`, off the main actor, off the critical save). Saving a session must never block on, fail on, or be slowed by these features. If a model is unavailable or a pass throws, the session is already safely saved; the feature degrades to "no labels / no cleaned view" and logs, it never corrupts or loses the session.
6. **The `[mm:ss]` timeline and the single monotonic T0 are sacred.** Diarization aligns to it; cleanup preserves it per-segment; nothing re-bases it.

**House style:** match `CLAUDE.md`'s conventions. Pin exact dependency versions in `Package.swift`. Read the pinned tag's actual source before calling any new API — do not trust this prompt's snippets over the real source at the tag you pin. Keep new persisted settings in `UserDefaults` with the existing pattern. Keep all on-device-AI calls behind the existing `#available(macOS 26)` guards. Add headless `--selftest-*` modes in `Main.swift`'s `SelfTest` dispatch for everything that can be tested without a mic/screen/permission.

---

## 1. Tech stack & exact version pinning

| Dependency | Version | Status | Notes |
|---|---|---|---|
| **FluidAudio** (`FluidInference/FluidAudio`) | **Pin the latest stable release tag** — check `https://github.com/FluidInference/FluidAudio/releases` and pin the newest non-pre-release `X.Y.Z` exactly in `Package.swift` (`.exact("X.Y.Z")`). | **NEW** | Apache-2.0 / MIT models. **No package dependencies** (clean — nothing transitive enters the graph). Swift SDK, CoreML on the ANE. We use its **batch** diarizer only. |
| WhisperKit (`argmaxinc/argmax-oss-swift`) | `1.0.0` (exact) | unchanged | Already pinned. We only change `DecodingOptions.language` and add multilingual model variants — no version bump. |
| KeyboardShortcuts (`sindresorhus`) | `2.4.0` (exact) | unchanged | No change. |
| FoundationModels (Apple, macOS 26 SDK) | system | unchanged | Reused for cleanup + custom modes. |
| EventKit (Apple) | system | **NEW USE** | No SPM entry; system framework. New optional permission (see §C and §Permissions). |

**FluidAudio — verified public API (reconcile against the pinned tag before use).** Confirmed from the repo's `Documentation/API.md` and README quick-start:

```swift
import FluidAudio

// One-time, anonymous CoreML model download (Pyannote Community-1 pipeline:
// powerset segmentation + WeSpeaker embeddings + VBx clustering), then fully offline.
let models = try await DiarizerModels.downloadIfNeeded()

let diarizer = DiarizerManager()              // or DiarizerManager(config: DiarizerConfig(...))
diarizer.initialize(models: models)

// samples MUST be 16 kHz mono Float32 — which is exactly what SampleSink already holds.
let result = try diarizer.performCompleteDiarization(samples, sampleRate: 16000)

for segment in result.segments {
    // Verify exact property names/types at the pinned tag. As of current docs:
    segment.speakerId          // speaker slot identifier (e.g. "Speaker 1" or an Int)
    segment.startTimeSeconds   // Double
    segment.endTimeSeconds     // Double
}
```

- Config: `DiarizerConfig` exposes `clusteringThreshold` (FluidAudio's docs note ~**0.7** ≈ 17.7% DER on AMI; the CLI default is 0.6). Use **0.7** as our default and surface it only as an advanced tunable, not a primary UI control.
- `DiarizerModels.downloadIfNeeded()` pulls FluidAudio's **re-hosted, converted CoreML bundles from its own HuggingFace repo — anonymously, no token, no gated-model agreement.** This is what keeps the no-account/offline story true. **Verify this is still token-free at the pinned tag**; if a future version ever requires a token, stop and flag it (it would break the privacy positioning) rather than wiring one in.
- There is also a higher-accuracy `OfflineDiarizerManager` (full pyannote-parity pipeline). Do **not** use it for this build — `DiarizerManager.performCompleteDiarization` is the simpler, documented batch path and is sufficient. Leave a one-line comment noting `OfflineDiarizerManager` as a future accuracy upgrade.

**WhisperKit — verified multilingual facts (reconcile at the 1.0.0 tag):**
- `DecodingOptions.language: String?` — ISO code (`"en"`, `"es"`, `"fr"`, …). `nil` ⇒ no forced language.
- `DecodingOptions.detectLanguage: Bool` — when used with `usePrefillPrompt: true`, runs language detection.
- `whisperKit.detectLanguage(audioArray:)` returns the detected language + per-language probabilities — use it for the "Auto" path (see §B).
- `DecodingTask.transcribe` vs `.translate` — `.translate` natively translates any source language → English. **Keep `.transcribe` for this build.** (Source-language transcription only. Translation is a later stage; do not wire `.translate` now.)
- **Multilingual models:** `openai_whisper-large-v3_turbo` is already multilingual. The `*.en` models are English-only. We will add the multilingual `openai_whisper-base` and `openai_whisper-small` variants (see §B).

---

## 2. Recommended internal build order

Build in this order to de-risk the core transcription path first, then layer features:

1. **Scaffolding & data model** — extend `TranscriptSegment` / `SessionMeta` with the new optional fields (all `decodeIfPresent`), add the new settings keys to `UserDefaults`, confirm old `session.json` still decodes. No behavior change yet.
2. **Feature B (multilingual)** — it touches the transcription core; get it correct and prove English is unchanged before adding anything else.
3. **Feature A (diarization)** — the flagship; new dependency; biggest new surface.
4. **Feature D (cleanup + custom modes)** — lowest risk, reuses FoundationModels.
5. **Feature C (calendar auto-capture)** — new permission + onboarding; ties the recording trigger together last.
6. **Self-tests + DoD pass.**

---

## Feature A — On-device speaker diarization (+ per-session speaker naming)

**Goal.** Label transcript segments with anonymous speakers ("Speaker 1/2/3…") computed fully on-device, aligned to the existing `[mm:ss]` timeline, and let the user rename speakers per session (persisted). This is the #1 missing feature versus MacWhisper/Otter/Fathom, and the only one of them that would be fully offline + unified with our RAG, visual capture, and library search.

**Where it runs.** 100% on-device (FluidAudio CoreML on the ANE). One-time anonymous model download, then offline.

**Default state.** OFF. A new Settings toggle **"Identify speakers (on-device)"**, persisted, default `false`. When off: no diarization runs, no model download, no speaker labels — `transcript.md` and `session.json` are byte-identical to today.

### Integration

- **New file `Diarizer.swift`** — a `DiarizerService` (actor or `@MainActor`-isolated class, your call, but model load/run must be off the main thread). Responsibilities:
  - `prepare() async throws` — `DiarizerModels.downloadIfNeeded()` + `DiarizerManager.initialize(models:)`, idempotent (load once, cache the manager). Surface download progress through the same `(message, fraction?)` callback shape the model downloader already uses, so the UI can show "Downloading speaker model…" the first time only.
  - `diarize(samples: [Float]) async throws -> [SpeakerTurn]` where `SpeakerTurn = (speaker: Int, start: Double, end: Double)`. Normalize FluidAudio's `speakerId` to stable, 1-based `Int` slots in first-appearance order (so labels read "Speaker 1, Speaker 2…" in the order they first speak — deterministic and testable).
  - Availability check: a static `isAvailable` (models downloadable / device capable). On any failure, callers degrade gracefully.
- **Alignment (`DocumentBuilder` or a small `SpeakerAlignment.swift`):** after `finalPass()` produces the clean `[TranscriptSegment]`, assign each segment a speaker by **maximum temporal overlap** with the `SpeakerTurn`s. Deterministic rule: for segment `[s,e]`, pick the turn maximizing `overlap([s,e],[turn.start,turn.end])`; if zero overlap with any turn, assign the nearest turn by midpoint distance. Keep this a **pure, unit-testable function** (segments + turns → labeled segments). Optionally coalesce consecutive same-speaker segments for display, but never drop a `[mm:ss]` anchor.
- **Run point:** in the `finalizeDocumentSession` flow, kick diarization in a **`Task.detached`** that runs the same `[Float]` buffer used by `finalPass`. When it completes, write the labels into `session.json` via `writeSessionJSON` (the session-only writer that leaves `transcript.md` untouched) **and** re-render `transcript.md`'s segment lines with labels (see rendering below). This mirrors how titling backfills off the save path. The save itself completes first and never waits on this.
  - For **imported** sessions (`Importer`), run the same diarization pass on the decoded buffer.

### Data model

- `TranscriptSegment` gains `speaker: Int?` (`decodeIfPresent`, default `nil`).
- `SessionMeta` gains:
  - `speakerCount: Int?` — distinct speakers found.
  - `speakerNames: [String: String]?` — slot → custom name, e.g. `{"1": "Alice", "2": "Bob"}`. `decodeIfPresent`, default `nil`/empty.
- All additive; old `session.json` decodes unchanged.

### Rendering

- **`transcript.md`:** when speakers are present, prefix each segment line with a resolved label, preserving the leading `[mm:ss]` so click-to-seek still works, e.g.
  `[00:12] **Speaker 1:** …text…` (or group consecutive turns under a `**Speaker 1:**` header line followed by its `[mm:ss]` lines — your choice, but the `[mm:ss]` tokens must remain line-anchored and parseable by `SearchIndex`/Viewer). When no speakers (toggle off, or diarization unavailable), render exactly as today (no label).
- **`Session Viewer`:** render the speaker label as a small styled chip on each line, **color-coded** by slot. Resolve display name through `speakerNames` (fallback "Speaker N"). Add an inline **rename affordance** (click the chip / a small "Rename speakers" control) that edits `speakerNames` and persists via the Viewer's owned-fields atomic write (the Viewer already merges only its owned fields + writes atomically — extend that allow-list with `speakerNames`; do not let it clobber titling/summary fields). Renames re-render the visible transcript and are reflected on next open.
- **`Library`:** optionally show the speaker count badge next to the existing slide/image badge. Search is unaffected (it indexes `transcript.md`, which now contains labels — that's fine; labels become searchable, e.g. searching a renamed speaker's name works).
- **Theme:** add a small ordered speaker color palette (`SpeakerColors.swift` or extend `Theme`), light/dark adaptive, ~6–8 distinct hues, cycling for >8 speakers. Reduced-motion/contrast safe.

### Failure modes & graceful degradation

- Model download fails / offline on first run → diarization is skipped, session is already saved without labels, a one-line status/log explains it; retried next session. Never blocks saving.
- AI/diarization throws mid-pass → caught; session keeps verbatim transcript with no labels.
- Single-speaker or silence → 1 speaker (or 0 → no labels); fine.
- Toggle off → exact no-op, no download.

### Non-regression invariants (assert)

- Toggle OFF ⇒ `transcript.md` + `session.json` byte/semantically identical to current build (use `--selftest-stream` and a recorded diff).
- Diarization never runs on, blocks, or alters the live streaming path or `finalPass` output text (it only *labels* segments post-hoc).
- Old sessions (no speaker fields) open and render identically to today.

### Self-tests (headless)

- `--selftest-diarize [audio.wav]` — if no file, synthesize a two-voice clip with `say -v` (two different voices) + `afconvert` to 16 kHz mono. Run `DiarizerService.diarize`, assert ≥1 speaker, print each turn (`Speaker N: start–end`). On a known 2-speaker synthetic clip, assert ≥2 distinct slots.
- `--selftest-align` — pure-function test: feed synthetic `[TranscriptSegment]` + synthetic `[SpeakerTurn]` with known overlaps; assert each segment gets the expected speaker, slots are 1-based in first-appearance order, and zero-overlap segments fall back to nearest. No model needed.

### Scope boundary (explicit)

- **IN:** on-device diarization, anonymous "Speaker N" labels, per-session rename (persisted), color-coding, alignment to `[mm:ss]`.
- **OUT (this build):** cross-session voiceprint identity / auto-naming a recurring speaker across sessions (FluidAudio's `enrollSpeaker`/WeSpeaker embeddings). Leave a clearly-commented hook noting where enrollment would attach, but do not build the voiceprint store now. (This is capability #2 — a later, separate build.)

---

## Feature B — Multilingual transcription

**Goal.** Remove the "English-first" limitation. Let the user transcribe in a selected language, or auto-detect the language, using WhisperKit's existing multilingual models — fully on-device. This is a low-cost, large-TAM unlock (international students, global teams).

**Where it runs.** On-device (WhisperKit multilingual model).

**Default state.** Language = **English** (current behavior preserved exactly). The `*.en` models remain the defaults. The language control is meaningful only when a multilingual model is active.

### Integration

- **`WhisperModel` enum (`AppModel.swift`):** add the multilingual variants alongside the existing three:
  - keep `openai_whisper-base.en`, `openai_whisper-small.en` (English-only, default-friendly),
  - add `openai_whisper-base`, `openai_whisper-small` (multilingual),
  - keep `openai_whisper-large-v3_turbo` (already multilingual).
  - Tag each case with `isMultilingual: Bool`. Persist selection as today.
- **New persisted setting `transcriptionLanguage`** — an enum/string: `"auto"` or an ISO code from a curated top set (at least: en, es, fr, de, it, pt, nl, ja, zh, ko, hi, ar, ru). Default `"en"`. Persist in `UserDefaults`.
- **`TranscriptionEngine.swift`:**
  - Plumb a `language: String?` into the `DecodingOptions` used by **both** `makeStreamer()` and `finalPass()`. Mapping: explicit code ⇒ `language = code`; `"auto"` ⇒ detect once (below) then pin.
  - **Detect-once architecture (critical):** do **not** auto-detect per streaming window (it's unstable and would flip languages mid-session). Instead:
    - **Live recording, "Auto":** on stream start, after ~the first 2–4 s of audio accumulate in the sink, call `whisperKit.detectLanguage(audioArray:)` once on that lead-in, set the session's resolved language, and use it as a fixed `language` for all subsequent streaming windows and the final pass. Surface the detected language unobtrusively in the status line.
    - **Explicit language:** skip detection; pin the chosen code throughout.
    - **Import, "Auto":** detect on a lead-in sample of the decoded file, then transcribe + finalPass with that fixed language.
  - **English-only model guard:** if the selected language is non-English (or "Auto") **and** the loaded model is a `*.en` variant, the language setting cannot be honored. Handle by: disabling/greying the language picker when a `*.en` model is selected, with an inline hint ("English-only model selected — switch to a multilingual model to change language"), and when the user picks a non-English language, offer to switch to the multilingual sibling (`base.en`→`base`, `small.en`→`small`) or to `large-v3-turbo`. Never silently produce wrong output.
- **Custom vocabulary interaction:** `customVocabulary` → `promptTokens` still applies; keep the **empty-list ⇒ `promptTokens` nil ⇒ exact no-op** rule. The tokenizer encodes vocab terms regardless of language; no change to that contract.
- **Save format unchanged:** `[mm:ss]` lines, folder layout, `DocumentBuilder` all identical — only the recognized text's language changes. Optionally store the resolved language in `SessionMeta.language: String?` (`decodeIfPresent`) for display; do not let it affect parsing.

### Settings UI

- A **Language** picker in `SettingsView` (Auto-detect + the curated list). Enabled state ties to the selected model's `isMultilingual`. Keep it visually consistent with the existing model/source pickers.

### Failure modes & graceful degradation

- Detection low-confidence → fall back to English and note it; never hang.
- Multilingual model not yet downloaded → same download-once flow as today (the existing progress UI handles it).

### Non-regression invariants (assert)

- Language = `"en"` (default) ⇒ `DecodingOptions` are byte-identical to today's pinned `"en"` options ⇒ existing English self-tests (`--selftest`, `--selftest-stream`) pass **unchanged**, output byte-identical.
- The streaming dedup/confirm algorithm is untouched; only the language token in `DecodingOptions` differs.

### Self-tests (headless)

- `--selftest-detect [audio.wav]` — run `detectLanguage` on a clip (synthesize a Spanish clip via `say -v` Spanish voice if none); print detected code + top probabilities; assert non-empty.
- `--selftest-multilingual [audio.wav] [--lang es]` — transcribe a non-English clip with a multilingual model and a pinned language; assert non-empty output and that, with `--lang es`, the path uses `language="es"` (and with no `--lang`, the Auto detect-once path resolves a language before transcribing). Write to a temp dir; never `~/Desktop/Transcripts`.

---

## Feature C — Calendar-aware, bot-free auto-capture

**Goal.** Detect upcoming/active video meetings from the user's calendar and offer (or auto-start) a local recording — **no bot joins the call**, because we just capture system audio on-device. This rides the hottest 2026 category trend (Granola's bot-free thesis) and our local capture is architecturally superior to a meeting bot.

**Where it runs.** On-device. EventKit reads the **local** calendar store; the app sends nothing out. New **optional** permission, requested lazily only when the feature is enabled.

**Default state.** OFF. New Settings section **"Calendar-aware capture"**, persisted, default `false`. Sub-options (all persisted):
- Mode: **"Prompt me when a meeting starts"** (default) vs **"Auto-start recording"**.
- Auto-capture source: **System Audio** (default) or **Mic + System**.
- Lead time: how early to fire (default 1 min before start; also fire if a linked meeting is already in progress at toggle-on).

### Integration

- **New file `CalendarMonitor.swift`:**
  - `EKEventStore`; request access with the macOS 14+ API `requestFullAccessToEvents` (handle the deprecated/old path defensively if needed). Only ever called when the feature is enabled.
  - A lightweight scheduler: a `Timer` (≈ every 60 s) querying `EKEventStore.events(matching:)` for events in a short forward window, **plus** observing `.EKEventStoreChanged` to re-evaluate on calendar edits. Keep CPU/wake cost minimal.
  - **Meeting-link detection (pure, testable):** a function `videoMeetingURL(in event:) -> URL?` that scans `event.url`, `event.notes`, `event.location` for known providers via robust regex: `zoom.us/j/…` & `zoom.us/my/…`, `teams.microsoft.com/l/meetup-join` & `teams.live.com`, `meet.google.com/…`, `*.webex.com/meet…`, `whereby.com/…`, generic `https://…` in the URL field as a weak fallback. Return the first strong match.
  - **Trigger logic (pure, testable):** given (now, event start/end, lead time, link present, already-recording?) → `.prompt | .autoStart | .ignore`. Never trigger while a recording is already in progress. De-dupe so one event fires at most once (track fired event identifiers for the session).
- **Trigger handling (in `AppModel` / `WindowManager`):**
  - **Prompt mode:** post a non-intrusive `Notifier` notification ("Meeting '<title>' is starting — Start recording?") and, if a window is open, an in-app banner with **Start** / **Ignore**. Start invokes the **existing** `startFlow` with the configured source — no change to capture.
  - **Auto-start mode:** call `startFlow` directly with the configured source. Show a clear, dismissible "Recording started for '<title>' (auto)" indicator so it's never silent/surprising.
  - **Title seeding:** pass the meeting title to the session so it pre-seeds `SessionMeta.title` (let on-device auto-titling still run, but prefer the meeting title when present — your call, but keep it deterministic and documented).
- **`OnboardingWindow.swift`:** add an **optional** Calendar step (same shape as the existing optional Notifications step) — explain bot-free local capture, offer to grant, degrade silently if denied.
- **Permissions / Info.plist:** add `NSCalendarsUsageDescription` and `NSCalendarsFullAccessUsageDescription` to the plist assembled in `Scripts/build_app.sh` (alongside the existing Mic/Screen-Recording strings). Copy: emphasize on-device/local.

### Failure modes & graceful degradation

- Calendar permission denied → feature silently inert; toggling it on re-prompts; everything else works.
- No calendar / no upcoming meetings → nothing happens.
- A meeting with no detectable link → no trigger (we only fire on actual video meetings to avoid noise) — make the link requirement a configurable nicety if trivial, else default to "link required."
- Already recording when an event fires → never interrupts.

### Non-regression invariants (assert)

- Feature OFF ⇒ **zero** EventKit calls, zero new permission prompts, zero behavior change. No `EKEventStore` is even instantiated.
- Auto/prompt only ever routes through the **existing** `startFlow`; the capture/stream code is untouched.
- New permission is optional + lazy + silent-if-denied (same contract as Notifications) — preserves "no account, works offline."

### Self-tests (headless)

- `--selftest-calendar` — cannot exercise live EventKit without a grant, so test the pure logic: feed sample strings (zoom/teams/meet/webex/whereby + non-meeting noise) to `videoMeetingURL(in:)` and assert correct detection/rejection; feed synthetic (now, start, lead, link, recording?) tuples to the trigger function and assert `prompt`/`autoStart`/`ignore` outcomes incl. the "never while recording" and "fire once" rules. The live calendar path is human-verified.

---

## Feature D — Transcript cleanup + custom summary modes

**Goal.** (#5) Optional, non-destructive transcript cleanup — remove fillers ("um", "ah"), false starts, fix punctuation/capitalization — via on-device FoundationModels, matching the polish of Wispr Flow / Superwhisper. (#9) Let users author named custom summary templates beyond the three fixed styles. Both fully on-device.

**Where it runs.** On-device FoundationModels (macOS 26), behind the existing `#available` guards. No new dependency.

**Default state.** Cleanup OFF (verbatim is the default view). Custom modes: none until the user adds one; the three built-in styles are unchanged.

### D1 — Transcript cleanup (#5)

- **Non-destructive, timestamp-preserving (critical).** Never rewrite `transcript.md` in place. Cleanup operates **per segment**: clean each `TranscriptSegment`'s text individually (drop fillers, tidy punctuation/caps) while **keeping its `[mm:ss]` timestamp and segment boundaries**. Store the result as a parallel cleaned form — either `transcript.clean.md` in the session folder **or** `cleanedText` per segment in `session.json` (`decodeIfPresent`). The verbatim `transcript.md` stays the canonical record, untouched.
- **Instruction discipline:** the FoundationModels prompt must be constrained to *clean within a segment*: remove disfluencies/false starts, fix punctuation/capitalization, **do not** add, summarize, paraphrase meaning, translate, or merge/split across timestamps. Run per-segment (or small batched segment groups that preserve boundaries) so timing can't drift.
- **Trigger:** a Settings toggle **"Clean up transcript (remove fillers, fix punctuation)"**, default OFF. When on, run the cleanup pass **off the save path** (`Task.detached`, like titling/diarization) after `finalPass`. Saving never waits on it.
- **Viewer:** a **Verbatim / Cleaned** toggle on the transcript. **Default = Verbatim** (trust first). Cleaned is opt-in and clearly labeled. Click-to-seek must work in both views (same `[mm:ss]` anchors).
- **Export:** when a cleaned form exists, the existing TXT/RTF/HTML/PDF/subtitle exporters may offer "verbatim vs cleaned" as a source — keep verbatim the default; do not change existing export defaults.

### D2 — Custom summary modes (#9)

- **Authoring:** in `SettingsView`, a small editor to create/edit/delete named modes. Each mode = `{ name: String, instructions: String }`. Persist as JSON in `UserDefaults` (or a small file in Application Support, your call — keep it simple and atomic). Ship 0 by default; the three built-in styles (TL;DR / Detailed / Executive) are unchanged and remain first-class.
- **Running:** the Summary panel's style switcher lists built-ins **plus** the user's custom modes. Selecting a custom mode calls the existing `Intelligence.run(instructions: <mode.instructions>, prompt: <transcript text>)` (reuse the single `run(instructions:prompt:)` wrapper). Use the cleaned text if the user has cleaned-view active, else verbatim — document the choice.
- **Caching:** cache custom-mode outputs in `session.json`'s existing `summaries` dictionary, keyed by mode name (namespaced to avoid colliding with built-in style keys). `decodeIfPresent`. Re-run on demand.
- **Empty/blank template ⇒ no-op** (don't call the model with an empty instruction).

### Failure modes & graceful degradation

- Apple Intelligence off / device ineligible / model not ready ⇒ cleanup toggle and custom modes disable cleanly (same availability check as `Summarizer`); verbatim transcript and built-in summary fallbacks are unaffected.
- Cleanup pass throws ⇒ caught; no cleaned form is written; verbatim untouched.

### Non-regression invariants (assert)

- Cleanup OFF ⇒ no cleaned artifact, `transcript.md` and `session.json` identical to today.
- Verbatim `transcript.md` is **never** mutated by cleanup, ever.
- The three built-in summary styles produce identical output to today; custom modes are purely additive.

### Self-tests (headless)

- `--selftest-cleanup [transcript.md]` — run the cleanup pass on a sample transcript; assert: timestamp count preserved and monotonic, segment count preserved (no merge/split), the input `transcript.md`/buffer is untouched, output non-empty when AI available; on unavailable AI, returns input unchanged (no-op) without throwing.
- `--selftest-custom-summary [transcript.md]` — run a sample custom template; assert non-empty output when AI available, clean no-op/fallback when unavailable; assert an empty template is rejected as a no-op.

---

## Cross-cutting: permissions & code signing

- **New permission:** Calendar only (`NSCalendarsUsageDescription` + `NSCalendarsFullAccessUsageDescription`), optional + lazy + silent-if-denied. No change to Microphone / Screen Recording / Notifications.
- **Signing is unchanged and must stay stable.** TCC binds grants to the code signature; the stable self-signed identity ("Transcriber Local Signing") and `Scripts/build_app.sh` flow stay exactly as in `CLAUDE.md`. Adding the Calendar usage strings and the FluidAudio dependency must not change the designated requirement in a way that disturbs existing Mic/Screen-Recording grants. After this build, existing grants must persist across rebuild (verify; if anything looks stale during smoke-test, the documented `tccutil reset` recipe applies — but it should not be necessary).
- **App Sandbox stays disabled** (personal-tool posture, per `CLAUDE.md`). EventKit access works under this posture with the usage strings present.

## Cross-cutting: data model & migration safety

- All new `SessionMeta` / `TranscriptSegment` fields are optional + `decodeIfPresent` with safe defaults. **No on-disk migration of existing folders.** Old sessions decode and render exactly as before (no speaker/cleaned/custom data → no labels, verbatim only, built-in summaries). Re-opening or re-listing an old session is a no-op for the new fields.
- The Session Viewer's atomic, owned-fields-only `session.json` writer must have its allow-list extended to include the **new fields it owns** (`speakerNames`, custom-mode cache entries it triggers) and **must not** clobber titling/summary/bookmark fields written elsewhere (last-writer-wins was already addressed for the Viewer — extend, don't regress it).

## Self-test additions (full list to wire into `Main.swift`'s `SelfTest` dispatch)

New, all headless, all writing only to temp dirs (never `~/Desktop/Transcripts`):
- `--selftest-diarize [audio.wav]`
- `--selftest-align`
- `--selftest-detect [audio.wav]`
- `--selftest-multilingual [audio.wav] [--lang xx]`
- `--selftest-calendar`
- `--selftest-cleanup [transcript.md]`
- `--selftest-custom-summary [transcript.md]`

**And re-run the entire existing suite** — every prior `--selftest*` (file, stream, summary, capture, ocr, doc, export, migrate, index, title, chat, ask, summary, import, mix, audio-save, srt, vocab, bookmarks) must still pass **unchanged**. The English `--selftest` / `--selftest-stream` outputs must be byte-identical to pre-build.

## Definition of done (checklist — all must be true)

- [ ] `Scripts/build_app.sh` builds green; the app launches (Dock + menu bar), records, and saves exactly as before with all toggles default.
- [ ] **FluidAudio** pinned to an exact stable tag in `Package.swift`; its API reconciled against that tag's real source; model download confirmed **anonymous/token-free**; bundle's localized/model resources handled if the build needs them.
- [ ] **Feature A:** toggle OFF ⇒ byte-identical output; toggle ON ⇒ on-device diarization labels segments aligned to `[mm:ss]`, per-session rename persists, speakers color-coded; runs off the save path; `--selftest-diarize` + `--selftest-align` pass. Cross-session voiceprint explicitly deferred with a hook comment.
- [ ] **Feature B:** default English byte-identical (existing English self-tests unchanged); multilingual model variants added; Auto = detect-once-then-pin; explicit language honored in streaming + finalPass; `*.en`-model guard prevents wrong-language output; `--selftest-detect` + `--selftest-multilingual` pass.
- [ ] **Feature C:** OFF ⇒ zero EventKit use / zero behavior change; ON ⇒ link detection + prompt/auto-start route through existing `startFlow`; optional Calendar permission lazy + silent-if-denied; onboarding step added; Info.plist strings added; `--selftest-calendar` pass.
- [ ] **Feature D:** cleanup non-destructive + timestamp-preserving, verbatim default, Viewer toggle works; custom modes author/run/cache, built-in styles unchanged; `--selftest-cleanup` + `--selftest-custom-summary` pass.
- [ ] `session.json` backward-compatible (old-schema file still decodes + opens); Viewer owned-fields writer extended without clobbering.
- [ ] Signing stable; existing TCC grants persist across rebuild.
- [ ] **Entire existing self-test suite passes unchanged**; new suite passes.
- [ ] No off-device transmission of user content anywhere; "everything stays on this Mac" still literally true for all four features.
- [ ] `CLAUDE.md` updated: new sources, new deps + pinned versions, new permission, new self-tests, the detect-once and non-destructive-cleanup decisions, and the explicit out-of-scope note (cross-session voiceprints, `.translate`/translation, `OfflineDiarizerManager`).

## Human smoke-test checklist (the ONLY acceptable pause points — hand this back at the end)

These can't be verified headlessly; pause and ask the human to run them after the build is green and all self-tests pass:
1. **Diarization, live:** record a real ≥2-speaker conversation (e.g. a call via Mic+System or a played multi-speaker clip), confirm sensible "Speaker 1/2…" labels on the timeline, rename a speaker, reopen the session, confirm the rename persisted and labels are searchable in the Library.
2. **Diarization first-run download:** confirm the speaker model downloads once (anonymously), then works offline.
3. **Multilingual:** with a multilingual model, transcribe a non-English source (a) with an explicit language and (b) on Auto-detect; confirm correct language output and the detected-language indicator.
4. **`*.en` guard:** select a `*.en` model + a non-English language; confirm the UI guides a switch rather than emitting wrong output.
5. **Calendar — prompt mode:** with a real upcoming Zoom/Teams/Meet event, confirm the prompt fires at lead time and **Start** records the meeting (bot-free); confirm **Ignore** does nothing.
6. **Calendar — auto-start mode:** confirm auto-start records at lead time with a clear non-silent indicator, seeds the meeting title, and never interrupts an in-progress recording.
7. **Calendar permission denial:** deny Calendar; confirm the feature is silently inert and the rest of the app is unaffected.
8. **Cleanup:** enable cleanup on a filler-heavy recording; confirm the Cleaned view removes fillers/fixes punctuation while Verbatim stays exact and both seek correctly; confirm `transcript.md` on disk is still verbatim.
9. **Custom modes:** author a custom summary mode (e.g. "Meeting minutes"), run it, confirm sensible output and that it's cached on reopen; confirm the three built-in styles are unchanged.
10. **Regression sweep:** existing live mic, live system audio, Mic+System mixer, playback-seek, file/video import, bookmarks, visual capture, and export all still behave exactly as before.
