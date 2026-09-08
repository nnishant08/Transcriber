# Phase 3 baselines (§10.0)

Captured by `Scripts/capture_baselines.sh`, which is committed in a commit that touches **no Swift
source**, so the pre-build baseline can be captured at any time by checking that commit out and
running it (see the header of the script for the exact sequence).

| File | What it pins | May it move in Phase 3? |
|---|---|---|
| `selftest-doc.txt` / `.md5` | Markdown document assembly | **No.** Word timings are `session.json`-only and slides are derived, so `DocumentBuilder`'s markdown is untouched. A moved md5 means something changed that was not asked to change. |
| `stream-baseline-whisper-file.txt` | `--selftest` one-shot file transcription, Whisper | **Yes, deliberately** — the engine changed. Preserved so the change is *visible* rather than silent. Compare the transcript TEXT only; the `RESULT (0.28s)` figure is wall clock. |
| `stream-baseline-whisper.txt` | `--selftest-stream`, Whisper | Same. `stream-baseline-parakeet.txt` sits alongside it after the build. |
| `align-legacy-fixture.json` | `SpeakerAlignment` output on a fixed turns+segments fixture | **No, on sessions with no word timings.** Word-boundary alignment (§7.7) must reproduce it exactly. Also asserted structurally in-code — see `SpeakerAlignment.assignWholeSegment`. |
| `codesign-requirement.txt` | The designated requirement | **No.** TCC binds grants to the signature; a change breaks every Mic / Screen Recording / Calendar grant. |
| `model-disk-usage.txt` | Model footprint before a second ASR engine exists | Grows — that is the point (§10.2a). The "before" number is what makes the "after" honest. |
| `perf-baseline.txt` | `finalPass` wall clock + peak RSS | Should **improve** (§10.3). |

`PROVENANCE.txt` records the commit, host OS and Swift version each capture was taken at. A baseline
without provenance is not a baseline.
