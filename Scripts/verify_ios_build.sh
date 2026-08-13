#!/bin/bash
# Compile SaidKit for iOS.
#
# THIS IS A GATE, NOT A CONVENIENCE. SaidKit is the cross-platform core; nothing stops a future
# edit from quietly importing AppKit or ScreenCaptureKit into it and breaking the iOS app that
# Phase 2 builds on top. A macOS `swift build` would never notice. This script would.
#
# SPM does not cross-compile to iOS reliably, so the build is driven through xcodebuild against
# SPM's generated scheme. `xcbeautify` is used when present and skipped when not (no tool dependency).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The #Preview macro plugin ships with full Xcode, not the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

DERIVED="${DERIVED:-/tmp/saidkit-ios}"
LOG="$(mktemp -t saidkit-ios)"

echo "==> Building SaidKit for generic/platform=iOS…"
if command -v xcbeautify >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild build \
        -scheme SaidKit \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$DERIVED" \
        2>&1 | tee "$LOG" | xcbeautify
    status=${PIPESTATUS[0]}
else
    xcodebuild build \
        -scheme SaidKit \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$DERIVED" \
        > "$LOG" 2>&1
    status=$?
fi

if [[ $status -ne 0 ]]; then
    echo ""
    echo "!! SaidKit does NOT compile for iOS. SaidKit must stay free of macOS-only frameworks."
    echo "-- errors ------------------------------------------------------"
    grep -E "error:" "$LOG" | sed 's|'"$ROOT"'/||' | sort -u | head -60
    echo "----------------------------------------------------------------"
    echo "full log: $LOG"
    exit 1
fi

echo ""
echo "==> PASS — SaidKit compiles for iOS."
rm -f "$LOG"
