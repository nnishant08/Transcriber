# The figures layer — build report

`CLAUDE.md` records **decisions**. This records **findings**: what turned out to be true when the
code and the frameworks were read rather than assumed, every place this wave diverged from its
build prompt and why, what was measured, and what was left out.

---

## 0. The gate, and the baseline

- **Phase 3 had landed.** Word-level timing (`WordTiming` / `validWords`), the non-mutating edit
  overlay (`EditOverlay` / `EditStore`) and hybrid retrieval (`SearchIndex` + `SemanticIndex` fused
  in `Intelligence.retrieve`) were all present, compiled and swept (`3b5b7e3`). The wave was built
  on `main` after fast-forwarding it to the Phase 3 branch.
- **Baseline captured before any source change** (§11): a clean build of the untouched tree, the
  full 54-mode self-test sweep (**54 PASS / 0 FAIL**), `Scripts/capture_baselines.sh`, and a copy of
  the baseline `Said.app`. The `--selftest-doc` case-1 md5 is `8f7e3033d39d5b62f663b5589a521538`.

## 1. What was built

| Piece | Where | Notes |
|---|---|---|
| Model, sidecar, anchoring, density, runs | `SaidKit/Figures.swift` | `Figure` (three anchors), `FigureOverlay.resolve` (the §P3 table), `FigureSidecar`/`FigureStore` (schema 1), `FigureDensity`, `FigureRuns` |
| Detector | `SaidKit/FigureDetector.swift` | Pure, AI-free, deterministic on both platforms |
| Labeller | `SaidKit/FigureLabeller.swift` | `FigureLabelBackend` seam; `OnDeviceFigureLabelBackend` = FoundationModels `@Generable`, gated |
| Extraction pass | `SaidKit/FigurePass.swift` | Off the save path; reuses labels; `needsExtraction` |
| Search | `SaidKit/SearchIndex.swift` | Raw + label terms; figure-led snippets; flag-gated freshness stamp |
| Ask / chat | `SaidKit/Intelligence.swift` | `figuresContext` — one block, existing citation path |
| Mac Viewer | `Said/SessionFigures.swift`, `SessionViewer.swift`, `TranscriptEditing.swift`, `RetranscribeSheet.swift` | Inline figures, the rail (side panel + sidebar row), the rebuilt header, re-extraction hooks |
| Mac settings + chain | `Said/AppModel.swift`, `SettingsPhase3.swift`, `SettingsView.swift` | The flag; the post-save step with activity reporting |
| iPhone | `iOS/SaidiOS/Screens/FiguresViews.swift`, `SessionScreen.swift`, `SessionModel.swift`, `Capture/RecordingModel.swift`, `Capture/SettingsStore.swift` | Inline (tap / long-press), the Figures tab, the collapsed header, thermal gating |
| Tests | `Said/SelfTestFigures.swift` (six modes), `iOS/SaidiOSTests/FiguresRoundTripTests.swift`, `Fixtures/figures/session` | See §5 |

## 2. Deviations forced by Phase 3's actual shape

1. **Edits are keyed by `(segmentIndex, wordIndex)`, not by "word IDs".** The prompt assumed
   stable word IDs. Phase 3 has none: `TranscriptEdit` names a segment index, a word index and the
   original text, and `EditOverlay` keeps a corrected word's timing in place. The figure's word
   anchor is therefore a word-index range, with `raw` as the fingerprint checked on every render.
   That gives exactly the table in §P3: an edit elsewhere in the turn leaves the indices and the
   text under them intact (render, range re-derived), an edit inside changes the text under them
   (drop).
2. **The character range is segment-relative, not a `transcript.md` offset.** A file offset dies on
   a speaker rename (the file is re-rendered with `**Name:**` labels), on the title landing (the
   file is *renamed*), and on any re-render — none of which touch the words. Reported in
   `CLAUDE.md` as a decision.
3. **"Overlay deletes the turn" cannot happen through the overlay.** `commitEdit` refuses an empty
   correction, so there is no delete. The row is covered by "the turn is gone" (segment index out
   of range after a re-transcription), which is tested.
4. **Re-transcription invalidation is by fingerprint, not by engine name alone.** `SessionMeta`
   carries `engine`/`engineModel`, but an in-place re-transcribe on the *same* engine would leave
   both unchanged while moving every word. The sidecar therefore hashes the verbatim segments'
   bounds and text plus the engine record.
5. **Extraction runs over the edited view.** The prompt's §13.4 wants re-extraction to "bring back
   the corrected version". With extraction over verbatim text that is impossible, so the pass
   detects over `EditStore.editedSegments`; rendering resolves against whatever view is shown, so
   Verbatim-with-edits simply drops what no longer matches there.
6. **`FigureCandidate` is a typealias of `Figure`.** One type, label optional, rather than two
   shapes and a conversion — a candidate that never reaches the labeller *is* the stored figure.
7. **The session "state machine" is three existing things, not one.** There is no per-session state
   object in the tree. `Transcribing` reads `EngineStatus.finalizing` for `AppModel.lastSessionDir`
   and the Viewer's re-transcribe run; `Diarizing` / `Titling` / `Cleaning up` / `Finding figures`
   read `AppModel.postSaveActivity`, a report the existing chain writes at each step; `Failed`
   reads `EngineStatus.error`. Post-save passes log and degrade rather than fail, so there is no
   "Failed" from them — none was invented.
8. **The Mac's inline hover reveals the label per figure; keyboard focus does the same.** Each
   figure is a real `Button`, so focus works in the tab order. The phone has no hover: long-press
   shows the label in a small alert that also offers "Play from mm:ss".
9. **No settings screen exists on the iPhone**, so `figuresEnabled` is read from the shared
   `UserDefaults` key (`SettingsStore.figuresEnabled`) and the Figures tab offers "Find figures"
   itself. A user with no Mac cannot flip the flag from the phone UI — noted as a follow-up.
10. **`--selftest-figures-bundle` gained `--write-fixture <dir>`**, which is how the committed
    cross-platform fixture was produced from the Mac binary rather than by hand.

## 3. Framework findings (measured, not recalled)

- `NumberFormatter.spellOut` parses **"twenty four" as 2004**, "seventy five" as 7005, **"fifth" as
  5**, "a hundred" as nothing and "two point four million" as nothing. Hyphenated "twenty-four" → 24.
  The detector hyphenates tens+units, splits at scale words, refuses ordinals, and composes
  "point" chains by hand; `.spellOut` still does the per-chunk parse the prompt requires.
- `.decimal` / `.currency` parse grouped digits (`2,400,000`, `$2,400`) only under `en_US`;
  `en_US_POSIX` returns nil for every grouped form.
- `NSDataDetector` has no currency or measurement type. It returns "3:30 pm" and "2pm" as dates,
  so clock times are excluded by regex before the date rule runs; it returns nothing for "by year
  end", "next sprint", "in Q3", "three weeks" — those are the lexicon's.
- FoundationModels guided generation returns the decoded value (`respond(to:generating:)`), so the
  labeller does no string parsing; an index the model invents is dropped rather than mislabelling
  a neighbour (tested).

## 4. Performance

Detection over a synthetic 90-minute fixture (1 157 segments, 11 481 word timings, two speakers):
**0.40 s** on this Mac (Apple Silicon, release build), against a stated budget of 2.0 s, asserted
by `--selftest-figures-detect`. Labelling is bounded by the 40-call cap; the calls themselves are
the model's and were not measured.

## 5. Tests

- **Six new macOS modes, all passing:** `--selftest-figures-detect` (52 assertions incl. the
  budget), `--selftest-figures-label` (18, stub backend), `--selftest-figures-anchor` (22),
  `--selftest-figures-bundle` (24), `--selftest-figures-search` (13),
  `--selftest-figures-offswitch` (14). Wired into `Scripts/verify_selftests.sh`.
- **iOS:** `FiguresRoundTripTests` — the Mac's committed fixture opens with no re-extraction and
  zero dropped anchors; the phone's detector reproduces the Mac's list exactly; a phone
  extraction keeps the Mac's labels and leaves the transcript alone; the off switch is inert;
  the density ceilings are ordered. Result in §6.
- **Non-regression:** the full prior sweep on the new binary, and the post-build
  `capture_baselines.sh` diffed against the pre-build capture. Result in §6.

## 6. Results

| Check | Result |
|---|---|
| `swift build -c release` + `Scripts/build_app.sh` | green; `Said.app` assembled and signed |
| Designated requirement | **identical** before/after: `identifier "com.said.mac" and certificate leaf = H"191d047d…"` |
| `Scripts/verify_ios_build.sh` (SaidKit for `generic/platform=iOS`) | **PASS** |
| iOS app build + `xcodebuild test` (`SaidiOSTests`) | **21 tests, 0 failures** — the 5 `FiguresRoundTripTests` cases all executed and passed (not skipped) |
| Full macOS sweep before the wave | 54 PASS / 0 FAIL |
| Full macOS sweep after the wave | **60 PASS / 0 FAIL** (the 54 prior modes + the 6 new ones) |
| `--selftest-doc` case-1 md5 | `8f7e3033d39d5b62f663b5589a521538` before and after — **unchanged** |
| `--selftest` transcript text | identical (only the wall-clock `RESULT (…s)` figure moves) |
| `--selftest-stream` final-pass text | identical; the intermediate live lines differ only by real-time feed timing, as documented |
| `--selftest-align`, `--selftest-edit`, `--selftest-slides`, `--selftest-bundle` output | identical modulo NSLog timestamps |
| Detection over the 90-minute fixture | **0.40 s** (budget 2.0 s) |
| `figuresEnabled` default | `false`, asserted |
| Prime directive #1 (`transcript.md` never written) | asserted byte-for-byte in `--selftest-figures-bundle` and `--selftest-figures-offswitch` |

## 7. Thought about, decided against

- **Figures in slide OCR text.** Tempting — a number on a slide is often the one that matters — but
  it is `FrameEvent` content, not transcript content, has no word timings to anchor to, and the
  prompt draws that line. Not built.
- **Bare 4-digit numbers as years.** Not figures (no unit), so nothing to do; a year with a unit
  ("2024 units") is a count, correctly.
- **A figures-specific Ask template.** Explicitly not: one context block, existing citations.
- **Indexing the raw string only once.** The raw tokens are already in the transcript's term
  table; adding them again nudges a session where "240" is a *figure* above one where it is
  incidental. Kept, deliberately, and only while the flag is on.
- **Colouring the Failed dot red.** There is no red in the identity and the row may not define a
  colour; the muted `pause` family plus the word "Failed" is the honest rendering.
