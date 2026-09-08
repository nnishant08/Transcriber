#!/bin/bash
# Said — capture the Phase 3 non-regression baselines (§10.0).
#
# WHY THIS SCRIPT EXISTS, AND WHY IT IS ITS OWN COMMIT
# ----------------------------------------------------
# Several Phase 3 guarantees compare against "the build before Phase 3". Those fixtures cannot be
# reconstructed after the ASR engine changes — once Parakeet is the default, the old Whisper output
# is gone. The script is therefore committed FIRST, in a commit that touches no Swift at all, so the
# pre-build baseline can still be captured at any time by checking that commit out:
#
#     git checkout <the "Phase 3: capture baselines" commit>
#     Scripts/build_app.sh && Scripts/capture_baselines.sh
#     git checkout claude/phase-3-transcription-core-8g38vc
#     cp -R /tmp/said_baselines/* Fixtures/baselines/ && git add Fixtures/baselines && git commit
#
# Re-run it AFTER the Phase 3 build too (same command) and diff the two directories: that diff is
# the evidence for §10.1's "what must stay identical / what may move".
#
# It runs the app's own headless self-tests and records their output. It writes only to $OUT.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${1:-/tmp/said_baselines}"
BIN=".build/release/Said"
mkdir -p "$OUT"

if [[ ! -x "$BIN" ]]; then
    echo "!! $BIN not found — run Scripts/build_app.sh first." >&2
    exit 1
fi

echo "==> Writing baselines to $OUT"
{
    echo "captured:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "commit:    $(git rev-parse HEAD)"
    echo "dirty:     $(git status --porcelain | wc -l | tr -d ' ') file(s)"
    echo "host:      $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) $(uname -m)"
    echo "swift:     $(swift --version 2>&1 | head -1)"
} > "$OUT/PROVENANCE.txt"

# ---- 1. Document assembly. The md5 here MUST NOT MOVE across Phase 3 (§4.4, §10.1): word timings
#         are a session.json-only addition and slides are derived, so markdown assembly is untouched.
#         NOTE: --selftest-doc PRINTS the rendered markdown; it does not compute a digest itself.
#         The "case-1 md5" CLAUDE.md refers to is the digest OF THAT OUTPUT, taken here. Case 1 is
#         everything before the "(frames case)" banner, so it stays exactly comparable to
#         pre-Phase-2 captures even as case 2 grows.
echo "--> --selftest-doc"
"$BIN" --selftest-doc > "$OUT/selftest-doc.txt" 2>&1
sed -n '1,/== document-builder self-test (frames case) ==/p' "$OUT/selftest-doc.txt" \
    | sed '$d' > "$OUT/selftest-doc-case1.txt"
{
    printf 'case1  '; md5 -q "$OUT/selftest-doc-case1.txt" 2>/dev/null || md5sum "$OUT/selftest-doc-case1.txt" | cut -d" " -f1
    printf 'full   '; md5 -q "$OUT/selftest-doc.txt"       2>/dev/null || md5sum "$OUT/selftest-doc.txt"       | cut -d" " -f1
} > "$OUT/selftest-doc.md5"

# ---- 2. Transcription output. This one IS ALLOWED TO MOVE — it is the deliberate retirement of the
#         byte-identity directive — which is exactly why the pre-build text has to be preserved here.
#         Only the transcript TEXT is comparable; the "RESULT (0.28s)" timing figure is wall clock.
echo "--> --selftest (file transcription)"
"$BIN" --selftest /tmp/transcriber_test.wav > "$OUT/stream-baseline-whisper-file.txt" 2>&1
echo "--> --selftest-stream (streaming + finalPass)"
"$BIN" --selftest-stream /tmp/tr_long_48k_stereo.wav > "$OUT/stream-baseline-whisper.txt" 2>&1

# ---- 3. Speaker alignment on a fixed fixture (§7.7). Word-boundary alignment must produce
#         byte-identical output to this on any session with no word timings.
echo "--> --selftest-align"
"$BIN" --selftest-align > "$OUT/selftest-align.txt" 2>&1
"$BIN" --selftest-align --emit-fixture "$OUT/align-legacy-fixture.json" > /dev/null 2>&1 \
    || echo "   (note: --emit-fixture is a Phase 3 addition; absent on a pre-Phase-3 binary)"

# ---- 4. The designated requirement. TCC binds permission grants to the code signature, so this
#         string must be identical before and after or every grant breaks (§5.6, §11).
echo "--> codesign designated requirement"
if [[ -d "$ROOT/Said.app" ]]; then
    codesign -d -r- "$ROOT/Said.app" > "$OUT/codesign-requirement.txt" 2>&1
    codesign -dv --verbose=4 "$ROOT/Said.app" >> "$OUT/codesign-requirement.txt" 2>&1
else
    echo "Said.app not present — run Scripts/build_app.sh" > "$OUT/codesign-requirement.txt"
fi

# ---- 5. Model disk footprint (§10.2a). Phase 3 leaves two ASR engines resident; the "before"
#         number is what makes the "after" number meaningful.
echo "--> model disk footprint"
{
    for d in "$HOME/Library/Application Support/FluidAudio/Models" \
             "$HOME/Documents/huggingface" \
             "$HOME/Library/Application Support/com.said.mac" \
             "$HOME/Library/Caches/com.said.mac"; do
        if [[ -d "$d" ]]; then
            echo "### $d"
            du -sh "$d" 2>/dev/null
            find "$d" -maxdepth 3 -mindepth 1 -type d -exec du -sh {} \; 2>/dev/null | sort -h
            echo
        fi
    done
} > "$OUT/model-disk-usage.txt" 2>&1

# ---- 6. Performance reference points (§10.3). finalPass wall clock and peak RSS on a long file.
#         `--selftest-stream` already runs a streamer + a full final pass, so it is the stand-in.
echo "--> finalPass wall clock + peak memory"
{
    echo "### /usr/bin/time -l  --selftest-stream /tmp/tr_long_48k_stereo.wav"
    /usr/bin/time -l "$BIN" --selftest-stream /tmp/tr_long_48k_stereo.wav 2>&1 | tail -30
} > "$OUT/perf-baseline.txt" 2>&1

echo
echo "==> Done. $(ls -1 "$OUT" | wc -l | tr -d ' ') artifacts in $OUT"
ls -la "$OUT"
