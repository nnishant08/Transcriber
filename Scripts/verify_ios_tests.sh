#!/bin/bash
# Run the iOS unit tests on a simulator.
#
# These cover what the Mac CLI suite cannot: the audio-session state machine, iOS storage layout,
# crash recovery, and the cross-platform .said round trip from the iPhone side. They drive the
# CaptureControl primitives directly rather than AVAudioSession — testing the notifications
# themselves would only test AVFoundation.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Pick an available iPhone simulator rather than hardcoding a model — the destination named in the
# build prompt (iPhone 16) does not exist on every machine, and a missing destination reads as a
# test failure rather than as a setup problem.
DEVICE="${IOS_SIM_DEVICE:-}"
if [[ -z "$DEVICE" ]]; then
    DEVICE=$(xcrun simctl list devices available \
        | grep -oE 'iPhone [0-9]+[^(]*' | head -1 | sed 's/[[:space:]]*$//')
fi
if [[ -z "$DEVICE" ]]; then
    echo "!! No iPhone simulator available. Install one via Xcode ▸ Settings ▸ Components."
    exit 1
fi

echo "==> Testing on: $DEVICE"
LOG="$(mktemp -t saidios-tests)"
xcodebuild test \
    -project Said-iOS.xcodeproj \
    -scheme SaidiOS \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -derivedDataPath /tmp/saidios-tests \
    CODE_SIGNING_ALLOWED=NO > "$LOG" 2>&1
status=$?

if [[ $status -ne 0 ]]; then
    echo ""
    echo "!! iOS tests FAILED"
    grep -E "error:|failed|XCTAssert" "$LOG" | sed "s|$ROOT/||" | sort -u | head -40
    echo "full log: $LOG"
    exit 1
fi

grep -E "Test Suite .* passed|Executed .* tests" "$LOG" | tail -3
echo "==> PASS — iOS tests green."
rm -f "$LOG"
