#!/bin/bash
# Said — full headless self-test sweep. Judges by exit code. Verify-only; writes to /tmp.
#
# Ends with the iOS compile gate (Scripts/verify_ios_build.sh): a green self-test sweep on macOS
# says nothing about whether SaidKit still compiles for iPhone, and that is the one regression
# nobody would notice until Phase 2.
BIN=".build/release/Said"
LOG_DIR="/tmp/said_verify_logs"; mkdir -p "$LOG_DIR"
PASS=0; FAIL=0; SKIP=0
declare -a FAILED
run() {                       # run <label> <timeout-seconds> <args...>
  local label="$1"; shift
  local secs="$1"; shift
  # Slashes in a label would be read as directory separators in the log path (and the
  # redirect would fail before the binary ever ran), so flatten them along with spaces.
  local safe="${label// /_}"; safe="${safe//\//-}"
  local log="$LOG_DIR/${safe}.log"
  printf "%-34s " "$label"
  # perl-based timeout (macOS has no coreutils `timeout` by default)
  perl -e 'alarm shift; exec @ARGV' "$secs" "$BIN" "$@" > "$log" 2>&1
  local code=$?
  if   [ $code -eq 0 ];  then echo "PASS"; PASS=$((PASS+1))
  elif [ $code -eq 142 ]; then echo "TIMEOUT (${secs}s)"; FAIL=$((FAIL+1)); FAILED+=("$label: timeout")
  else echo "FAIL (exit $code)"; FAIL=$((FAIL+1)); FAILED+=("$label: exit $code")
  fi
}

echo "=== Core (Prompt 0/1) ==="
run "file transcription"        300 --selftest /tmp/transcriber_test.wav
run "streaming + finalPass"     300 --selftest-stream /tmp/tr_long_48k_stereo.wav
run "summary (availability)"    120 --summarize
run "document/timeline merge"    60 --selftest-doc
run "HTML + PDF export"         120 --selftest-export
run "legacy migration"           60 --selftest-migrate
run "search index"               60 --selftest-index
run "title + tag generation"    120 --selftest-title

echo "=== Prompt 2 ==="
run "session chat"              180 --selftest-chat
run "cross-session ask"         180 --selftest-ask
run "summary suite"             300 --selftest-summary
run "audio + video import"      600 --selftest-import
run "mic+system mixer"           60 --selftest-mix
run "audio save round-trip"      60 --selftest-audio-save
run "SRT / VTT cues"             60 --selftest-srt
run "custom vocabulary"         120 --selftest-vocab
run "bookmarks persistence"      60 --selftest-bookmarks
run "pause / auto-pause"         60 --selftest-pause

echo "=== Stage 1 ==="
run "diarization (FluidAudio)"  900 --selftest-diarize
run "speaker alignment (pure)"   60 --selftest-align
run "language detection"        600 --selftest-detect
run "multilingual transcribe"   600 --selftest-multilingual
run "calendar trigger rules"     60 --selftest-calendar
run "transcript cleanup"        300 --selftest-cleanup
run "custom summary modes"      300 --selftest-custom-summary

echo "=== Stage 2 ==="
for t in minutes decisions qa interview soap dap flashcards quiz studyguide shownotes titles blog; do
  run "generate: $t"            300 --selftest-generate --template "$t"
done
run "audiogram export"          300 --selftest-audiogram
run "vertical packs"             60 --selftest-packs
run "PII/PHI redaction"         120 --selftest-redact
run "retention sweep"            60 --selftest-retention
run "encryption seam"           120 --selftest-encrypt

echo "=== Screen recording ==="
run "screen-recording encoder"   120 --selftest-screenrec

echo "=== Phase 2 (visual timeline) ==="
run "frames / SlideOCR"          300 --selftest-frames

echo "=== Phase 1 (cross-platform core) ==="
run ".said bundle round-trip"    180 --selftest-bundle
run "portability seams"           60 --selftest-portability
run "theme tokens"                60 --selftest-theme

echo
echo "================================================"
echo "PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP   TOTAL: $((PASS+FAIL+SKIP))"
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "--- failures ---"
  printf '  %s\n' "${FAILED[@]}"
  echo "logs: $LOG_DIR"
fi
echo "================================================"

# The iOS compile gate. Last, because it is the slowest and the most structural: it is what stops
# SaidKit from silently re-acquiring an AppKit/ScreenCaptureKit dependency between now and Phase 2.
echo
if [ "${SKIP_IOS:-0}" = "1" ]; then
  echo "==> SKIPPING iOS gate (SKIP_IOS=1)"
else
  if ! "$(dirname "$0")/verify_ios_build.sh"; then
    echo "!! iOS gate FAILED — SaidKit no longer compiles for iOS."
    FAIL=$((FAIL+1))
  fi
fi

exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
