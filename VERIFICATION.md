# Verification — 2026-08-04

Headless verification pass over the three unverified build waves (**Prompt 2**, **Stage 1**, **Stage 2**).
Phases 0–4 are complete. **Phase 5 (human GUI smoke-tests) has NOT been run** — the checklist in §6 of the
pass document is handed back and the waves stay `[~]` in `CLAUDE.md` until a human completes it.

## Environment

| | |
|---|---|
| macOS | 26.5.2 (build 25F84) |
| Arch | arm64 (Apple Silicon) |
| Xcode | 26.6 at `/Applications/Xcode.app` (`xcode-select` → `/Library/Developer/CommandLineTools`, as documented) |
| Swift | 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101) |
| git SHA | `776e367` |
| Working tree at preflight | **clean** |
| Apple Intelligence | **AVAILABLE** (`isAvailable: true`) — the AI paths were genuinely exercised, not the fallback |

### What was actually tested (read this before trusting the tally)

The tested tree is **not** pristine `776e367`. It is `776e367` plus three sets of changes:

| File | Origin | Nature |
|---|---|---|
| `Sources/Transcriber/GenerationTemplates.swift` | **this pass** | the show-notes fix (finding F2) |
| `Scripts/verify_selftests.sh` | **this pass** | new, the committed sweep runner |
| `Sources/Transcriber/Main.swift` (+6 lines) | **the user, concurrently** | `--selftest-sysaudio` dispatch |
| `Sources/Transcriber/SysAudioProbe.swift` (new, 163 lines) | **the user, concurrently** | system-audio diagnostic probe |

The user was actively developing and using the app while this pass ran. Their `SysAudioProbe` addition is
purely additive (a new file + a new CLI dispatch arm; it touches no verified path), but it **was compiled
into every binary tested here**. Its stated motivation — *"can't transcribe when the speaker is turned
off"* — is an open live issue and is directly relevant to GUI item **A3**.

`CLAUDE.md` source-of-truth check passed (mentions Stage 2, deployment floor reads macOS 14, FluidAudio 0.15.2).

Fixtures regenerated deterministically via `say` + `afconvert`: `/tmp/transcriber_test.wav` (16 kHz mono),
`/tmp/tr_long_48k_stereo.wav` (48 kHz stereo).

## Phase 1 — Build & signing

- `swift build -c release` → **exit 0, 0 errors.**
- **Warnings: 3, all pre-existing and expected** — `onChange(of:perform:)` deprecations at
  `TranscriptCanvas.swift:32`, `:33`, `:34`. These are the known Stage-1 deployment-floor artifacts that
  `CLAUDE.md` documents as deliberately left alone. **No new warnings anywhere.**
- `Scripts/build_app.sh` → **initially FAILED** (finding **F1**, resolved — see Findings).
  After resolution: exit 0, bundle assembled and signed.

Bundle assertions, all passing:

| Check | Result |
|---|---|
| SPM resource bundle present | ✅ `Transcriber_Transcriber.bundle` **and** `KeyboardShortcuts_KeyboardShortcuts.bundle` |
| Packs shipped inside it | ✅ `pack-education/finance-sales/legal/medical.json` (4/4) |
| Signing identity | ✅ `Authority=Transcriber Local Signing` — **stable, not ad-hoc** |
| `codesign --verify --deep --strict` | ✅ valid |
| Designated Requirement | ✅ `identifier "com.nikhil.transcriber" and certificate leaf = H"191d047dcb11973f54a46ca7a065e6262584dc58"` |
| Bundle identifier | ✅ `com.nikhil.transcriber` (unchanged) |
| `LSMinimumSystemVersion` | ✅ `14.0` (Stage-1 floor) · `LSUIElement` = `false` (Dock + menu bar) |
| Usage descriptions | ✅ Microphone, ScreenCapture, Calendars, CalendarsFullAccess — all 4 present |

**The DR is byte-identical before and after the code fix**, so the human's Mic / Screen-Recording TCC
grants survive this rebuild.

## Phase 2 — Self-test sweep

Runner committed at `Scripts/verify_selftests.sh` (executable, non-interactive, per-test timeout, `/tmp` only).

### Final result: **PASS 44 · FAIL 0 · SKIP 0 · TOTAL 44**

Every one of the 44 invocations passed on the final run, with Apple Intelligence **available** — so the
AI-dependent tests (`chat`, `ask`, `summary`, `title`, `cleanup`, `custom-summary`, all 12 `generate`
templates) verify the **real model path**, not the clean-fallback path.

Run history:

| Run | Result | Notes |
|---|---|---|
| 1 | 40 PASS / 4 FAIL | 3 harness bugs (F3) + 1 real bug (F2) |
| 2 | 43 PASS / 1 FAIL | F3 fixed; F2 partially fixed, still intermittent |
| 3 (final) | **44 PASS / 0 FAIL** | F2 fully fixed |

Notable log contents read in full rather than judged by exit code:

- **`--selftest-encrypt`** (the most important Stage-2 test) — all 7 assertions pass:
  OFF on-disk bytes identical (passthrough) · OFF read-back identical · ON bytes **not** plaintext ·
  ON decrypts to exact plaintext · `transcript.md` encrypted on disk · in-memory index finds the term ·
  **no plaintext cache written while encrypted**.
- **Clinical templates** — SOAP and DAP are labelled at all three levels: template name `SOAP note (draft)`,
  body heading `# SOAP note (draft)`, and the disclaimer
  `_Draft — not a medical record. Review and edit before any clinical use._`
- **`--selftest-packs`** — 4 packs parse, all template ids valid, vocab unions with user vocab, and
  **`empty selection ⇒ empty vocab (no-op)`** is explicitly asserted.
- **`--selftest-slidechat`** — reports `macOS-26 build: image input unavailable (text+OCR fallback)`, i.e.
  Feature D's fallback is the live path on this machine, as designed.

**Model downloads:** the FluidAudio speaker models were **already cached** (`~/Library/Application Support/
FluidAudio/Models/speaker-diarization`, dated 2026-06-12), so **no download occurred during this run and
its network behaviour could NOT be observed live.** Anonymity is therefore verified only at source level
(no `HF_TOKEN`-style env var is set; `Diarizer.swift:7` documents that a Bearer header is attached only when
one exists). Honest status: **not live-verified.**

## Phase 3 — Non-regression proofs

| Proof | Value | Verdict |
|---|---|---|
| `--selftest-doc` md5 | `6fed3454943fed2e4d9a92d98ec8a742` | **BASELINE ESTABLISHED** (see note) — stable across 3 consecutive runs, and **identical before and after** the show-notes fix |
| file transcription md5 (timing stripped) | `d56e63a3134e5e52a2c67093096f5a65` | baseline established |
| stream transcription md5 (timing stripped) | `1e08507de79a6646dc2550f41f9fb51f` | baseline established |
| default `session.json` additive keys | `[]` (meta) and `[]` (segments) | **CLEAN** |
| old-schema decode | decodes, new fields default empty | **OK** |
| empty-vocabulary no-op | `empty → nil`, `blank → nil`, `non-empty → 15 tokens` | **OK** |

**Note on the baseline:** `CLAUDE.md` asserted the `--selftest-doc` md5 was "identical" after Stage 2 but
**never recorded the value**, so there was nothing to compare against. The value above is recorded here as
the named baseline for future waves. It is not a match against a prior recorded hash — it is a new anchor.

**Defaults-off detail.** Both default-settings sessions produced by `--selftest-import` carry meta keys
`[actionItems, audioFile, bookmarks, chapters, date, durationSeconds, imported, modelName, schemaVersion,
sourceLabel, summaries, tags, title]` (+`modeLabel` on the video one) — i.e. **none** of
`speakerCount`, `speakerNames`, `language`, `generatedArtifacts`, `retentionLocked`. Segments carry only
`start`, `end`, `text` — no `speaker`, `cleanedText`, or `redactedText`.

**Old-schema decode** is covered by `--selftest-bookmarks`, which writes a byte-identical pre-Prompt-1
`session.json` (`{"meta":{"date":0,"sourceLabel":"Mic","modelName":"m"},"segments":[],"frames":[]}`), runs
the real `DocumentBuilder.readSession` on it, and asserts it decodes with `bookmarks` empty. A supplementary
fixture at `/tmp/tr_legacy_decode/` matches that shape.

### `~/Desktop/Transcripts` — 15 before, **21** after (investigated; NOT a test leak)

The count changed, which the pass document flags as a potential P1. It was investigated to conclusion and
the six new folders are **the user's own GUI activity**, not test leakage. Evidence:

1. `Transcriber.app` was **running throughout** as PID 10130, started **11:56:31**; the first new session
   folder is **11:56:39** — 8 seconds later. Elapsed runtime at inspection: 6 h 23 m.
2. The folders contain **real recorded content** (a lecture on associative / non-associative learning and
   habituation) with saved `audio.m4a`, sourced from `Mic` and `System Audio` — not the synthetic fixtures
   the self-tests use (photosynthesis / revenue / Priya / sine waves).
3. The newest folder is timestamped **18:01**, roughly five hours *after* the headless phases finished (~12:53).
4. **No self-test log references `Desktop/Transcripts`**; every self-test output path is under `/tmp`.
5. `AppModel.transcriptsDirectory` appears exactly once in `Main.swift` — as the default for `--retag`,
   a maintenance utility that was **never invoked** in this pass.

**Conclusion: the headless phases wrote nothing to `~/Desktop/Transcripts`.** The pre-existing
`~/Desktop/Transcripts_backup_2026-06-10_17-37-22` is from June and was not touched.

## Phase 4 — Static audits

### 4.1 On-device guarantee — **CLEAN**

`grep` for `URLSession|URLRequest|http://|https://|NWConnection|CFNetwork` across `Sources/Transcriber/`
returns **zero actual network calls**. Every hit classified:

| Hit | Classification |
|---|---|
| `CalendarMonitor.swift:18,45` | **URL-scheme text matching** — a regex detecting meeting links inside calendar event fields. Local string work; no request is made. |
| `Main.swift:1345–1357` (11 hits) | **test string literals** — fixture URLs fed to the pure link detector in `--selftest-calendar`. |

There is **no `URLSession`, `URLRequest`, `NWConnection`, or `CFNetwork` anywhere in the app's own source.**
All network I/O lives inside the pinned dependencies (WhisperKit / FluidAudio one-time model downloads).

Negative space confirmed: `grep -niE "apikey|api_key|bearer |analytics|telemetry|sentry|mixpanel|amplitude|firebase"`
over `Sources/` and `Package.swift` returns **one hit, a comment** (`Diarizer.swift:7`, describing that
FluidAudio attaches a Bearer header only when an `HF_TOKEN` env var exists). **Zero API keys, tokens,
accounts, telemetry, analytics, or crash-reporting SDKs.**

Dependencies are pinned exactly as documented: WhisperKit `1.0.0` (via `argmax-oss-swift`),
KeyboardShortcuts `2.4.0`, FluidAudio `0.15.2`. **Nothing was bumped.**

### 4.2 Feature D double-gating — **CONFIRMED**

- Compile gate `#if TRANSCRIBER_MACOS27` **and** runtime gate `if #available(macOS 27, *)` are both present
  around the image call (`Intelligence.swift:89–90`), and again around `answerWithSlides`
  (`Intelligence.swift:111`, `@available(macOS 27, *)` at `:116`).
- `Scripts/build_app.sh:28` leaves `MACOS27` **off by default** (`"${MACOS27:-0}" == "1"`).
- The unverified-SDK comment **survives** at `Intelligence.swift:112`: *"VERIFY against the macOS 27 SDK:
  the exact image value type accepted…"*, plus a second marker at `:132`.
- The macOS-26 text+OCR fallback is the live path, confirmed at runtime by `--selftest-slidechat`.

### 4.3 Defaults are OFF — **ALL CONFIRMED**

| Setting | Read | Fresh-install default |
|---|---|---|
| `diarizationEnabled` | `d.bool(forKey:)` | `false` ✅ |
| `transcriptionLanguage` | `d.string(...) ?? "en"` | `"en"` ✅ |
| `cleanupEnabled` | `d.bool(forKey:)` | `false` ✅ |
| `customSummaryModes` | `d.data(forKey:)` | empty ✅ |
| `enabledPackIDs` | `stringArray(...) ?? []` | empty ✅ |
| `retentionPolicy.autoDeleteEnabled` | struct default `= false` | `false` ✅ |
| `encryptionEnabled` | `bool(forKey:)` | `false` ✅ |
| `encryptionRequireTouchID` | `bool(forKey:)` | `false` ✅ |
| `calendarCaptureEnabled` | `d.bool(forKey:)` | `false` ✅ |
| `calendarAutoStart` | `d.bool(forKey:)` | `false` ✅ |

No defaulted-true toggle exists. (`saveAudioEnabled` is explicitly `?? true` — the documented, intended
default-ON from Prompt 2, not a regression.)

### 4.4 Entitlement seam — **INTACT**

`LocalEntitlementProvider.isEntitled(_:) -> true` for everything (`Entitlements.swift:25`). Complete call-site
inventory — **this is the shopping list for a future pricing decision**:

| Site | Purpose |
|---|---|
| `Packs.swift:43` | `availablePacks` filter |
| `Packs.swift:53` | `setEnabled` guard |
| `Main.swift:1596–1598` | self-test assertions (pack / template / BYOK) |

`grep -niE "storekit|purchase|receipt|license|gumroad|paddle|lemonsqueezy"` returns **two comment lines**
in `Entitlements.swift` describing what is deliberately unbuilt. **No commerce SDK exists.**

### 4.5 Heavy work off the save path — **CONFIRMED**

`AppModel.swift:780–784` runs the post-save chain inside `Task.detached(priority: .utility)`, **serialized**
exactly as documented: index → `ensureTitle` → `DiarizationPass` (if enabled) → `CleanupPass` (if enabled),
so `session.json` read-modify-writes cannot race.

`transcript.md` writers: `DocumentBuilder.swift:200` (the canonical renderer) and `Main.swift:726` (a test
fixture). `CleanupPass` (`Cleanup.swift:96`) and `RedactionPass` (`Redaction.swift:121`) both write **only**
`writeSessionJSON`. `DiarizationPass` (`Diarizer.swift:72`) is the **single documented exception** that
re-renders `transcript.md` to add speaker labels.

### 4.6 `session.json` writer allow-list — **EXTENDED, NOT REGRESSED**

The Viewer re-reads from disk and merges only the fields it owns (`SessionViewer.swift:226–235`):
`summaries`, `actionItems`, `chapters`, `bookmarks`, `speakerNames` (Stage 1), `generatedArtifacts` and
`retentionLocked` (Stage 2), then calls `writeSessionJSON`. **Title and tags are deliberately absent from the
list**, so a concurrent `TitleBackfill` cannot be clobbered — the Prompt-2 fix holds and both later stages
extended it correctly.

## Phase 5 — Human GUI results

**NOT RUN.** The §6 checklist (Sections A–D) is handed back to the human. Nothing in it can be verified from
a terminal, and no item below has been marked.

## Findings

### F1 — Signing keychain locked; `build_app.sh` aborted mid-sign and left the bundle ad-hoc · **P1 · RESOLVED**

**What happened.** The first `Scripts/build_app.sh` run failed at the codesign step with
`errSecInternalComponent`. `security find-identity` *did* list "Transcriber Local Signing", so the script took
the stable-identity branch, but the isolated keychain (`~/Library/Keychains/transcriber-signing.keychain-db`)
was **locked**, making the private key unusable. Because `build_app.sh` runs under `set -euo pipefail`, it
aborted immediately — skipping its own `codesign --verify` and the de-quarantine step — and left the bundle in
a broken state reporting `Signature=adhoc`, with `codesign --verify --deep --strict` failing outright.

**Why it is P1.** Had the app been launched in that state, TCC would have seen a different code identity and
the human's Microphone and Screen-Recording grants would have broken — invalidating the entire GUI section.

**Resolution.** `security unlock-keychain -p "transcriber-local" …` (the password documented in
`Scripts/setup_signing.sh`), then a clean rebuild. Verified: `Authority=Transcriber Local Signing`, signature
valid, DR pinned to cert leaf `191d047d…`, **byte-identical to the pre-existing requirement.** No TCC impact.

**Not fixed in code, deliberately.** Teaching `build_app.sh` to unlock the keychain (or to fail loudly instead
of leaving a half-signed bundle) is a **change to the signing flow**, which rule 5 puts off-limits for this
pass. Recommended as a follow-up, for the human to decide:

```bash
security unlock-keychain -p "transcriber-local" ~/Library/Keychains/transcriber-signing.keychain-db
```

The keychain was created with `set-keychain-settings` (no auto-lock), so this most likely followed a reboot.
**If a build ever prints `errSecInternalComponent` again, run the unlock above before launching the app.**

### F2 — Show-notes generation intermittently failed to deserialize · **P2 · FIXED**

**Symptom.** `--selftest-generate --template shownotes` failed with
`Failed to deserialize a Generable type from model output` — **non-deterministically**, at roughly 2 failures
in 3 runs, with Apple Intelligence available. In the product this is a user clicking *Show notes* in the
Generation Studio and getting an error most of the time.

**Isolation.** Stress-testing the other nested-`@Generable`-array templates ruled out a general problem:
`flashcards` 3/3, `quiz` 3/3, `studyguide` 3/3, **`shownotes` 1/3**. `GenShowNotes` is structurally the same
shape as the passing `GenStudyGuide` (a nested struct array + a String), so the type shape was not the cause.

**Root cause — `GenChapter` violated the file's own two conventions**, and was the only type in the file to do so:

1. **Missing the empty-string sentinel.** Every other timestamp field offers the model an explicit escape
   hatch — `"[mm:ss] from the transcript, or empty"` (`GenDecision:40`, `GenQAPair:58`, `GenObjection:75`,
   `GenQuote:115`) or `"…otherwise an empty string"` (`GenActionItem:17`). `GenChapter.timestamp` had **none**,
   so a chapter with no confident timestamp had no sanctioned way to be expressed. `CLAUDE.md` documents this
   pattern deliberately: *"fields are non-optional with empty-string sentinels to sidestep Optional-Generable
   subtleties."*
2. **Timestamp led instead of followed.** Every sibling emits the constrained timestamp **after** prose
   (`task, owner, timestamp`; `question, answer, timestamp`; `quote, timestamp`). `GenChapter` alone led with
   it, forcing the model to produce a format-constrained field before any grounding context.

**Fix** (`GenerationTemplates.swift`, 3 lines) — bring `GenChapter` in line with its five siblings:
- added `, or empty` to the `timestamp` guide description;
- reordered to `title` then `timestamp`;
- `GenShowNotes.render()` now guards `timestamp.isEmpty` exactly as the sibling renderers do
  (`:49`, `:67`, `:84`, `:128`), so an empty timestamp yields `- Title` rather than a stray `- [] Title`.

**Verification.** Fix 1 alone: 6/6, then a failure in the next sweep → still flaky. Both fixes: **12/12
consecutive passes**, plus a clean 44/44 sweep. All 12 trials still emit real `[mm:ss]` chapters, so output
quality is unchanged — the model simply now has a legal way to say "no timestamp".

**No regression:** `--selftest-doc` md5 is identical before and after.

### F3 — Sweep runner mangled log paths for labels containing `/` · **P3 (harness only) · FIXED**

Three tests (`document/timeline merge`, `SRT / VTT cues`, `PII/PHI redaction`) reported `FAIL (exit 1)` on the
first run **without the binary ever executing** — their labels contain `/`, so `$LOG_DIR/${label// /_}.log`
resolved to a nonexistent subdirectory and the redirect failed first. This was a bug in the runner script
this pass authored (carried over verbatim from the pass document's template), **not in the app**. Fixed by
also flattening `/` → `-`. All three pass on re-run. No app code involved.

### Informational (no action taken)

- **FluidAudio download anonymity is not live-verified** — models were already cached, so no request was
  observable. Source-level evidence only. To verify properly: clear
  `~/Library/Application Support/FluidAudio/Models/` and watch the traffic during `--selftest-diarize`.
- **`--selftest-doc` had no recorded baseline** to compare against; one is established here.
- **Concurrent user changes** (`SysAudioProbe.swift`, `Main.swift`) were compiled into everything tested —
  see "What was actually tested".
- **`debugLog()` scaffolding** left in place per §10.

## Verdict

Judged strictly: self-tests alone do **not** verify a wave. Every wave remains gated on the §6 GUI checklist.

| Wave | Status | Basis |
|---|---|---|
| **Prompt 2** | **HEADLESS-VERIFIED — awaiting GUI** | 19/19 relevant self-tests pass with AI available; non-regression proofs clean |
| **Stage 1** | **HEADLESS-VERIFIED — awaiting GUI** | 7/7 self-tests pass; defaults-off proven; diarization/cleanup confirmed off the save path |
| **Stage 2** | **VERIFIED WITH FINDINGS — awaiting GUI** | 18/18 self-tests pass **after fixing F2**; encryption seam fully verified; entitlement seam intact |

**No wave is marked `[x]` in `CLAUDE.md` as a result of this pass.** `CLAUDE.md` will be updated only after a
human completes §6, per §8.2.

### Definition-of-done status

| Item | Status |
|---|---|
| Build exits 0, bundle has SPM resource bundle, stable signature validates | ✅ (after F1) |
| All 44 self-test invocations run; 0 failures | ✅ (F2 fixed and re-run green) |
| `--selftest-doc` md5 matches baseline | ✅ baseline **established** (none previously recorded) |
| File + stream transcription byte-identical modulo timing | ✅ baselines established |
| Default `session.json` has no additive keys | ✅ CLEAN |
| Pre-Prompt-1 `session.json` still decodes | ✅ |
| `~/Desktop/Transcripts` untouched by headless phases | ✅ (count change attributed to concurrent GUI use) |
| Every network call classified; zero carry user content; zero keys/telemetry | ✅ zero network calls in app source |
| Feature D double-gated, fallback default, SDK comment survives | ✅ |
| Every new setting defaults OFF/neutral | ✅ 10/10 |
| `Entitlements` grants all; no commerce SDK | ✅ |
| Human GUI checklist handed back, completed, recorded | ⬜ **OUTSTANDING** |
| `VERIFICATION.md` written; `CLAUDE.md` updated; runner committed | ◐ report + runner done; `CLAUDE.md` pending GUI |
