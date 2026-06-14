#!/bin/bash
# Build Transcriber and assemble a runnable, ad-hoc-signed .app bundle.
# No Xcode required (uses Swift Package Manager + Command Line Tools).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Transcriber"
CONFIG="${CONFIG:-release}"
APP="$ROOT/$APP_NAME.app"

# A dependency (KeyboardShortcuts) uses the SwiftUI #Preview macro, whose compiler
# plugin ships with full Xcode but NOT with the Command Line Tools. If Xcode is
# installed, point the build at it so the plugin resolves. (No sudo / xcode-select needed.)
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    echo "==> Using Xcode toolchain at $DEVELOPER_DIR"
fi

# Stage 2, Feature D (Multimodal Slide Chat) needs the macOS 27 SDK (image input symbols exist only
# there). It is double-gated: the image call compiles ONLY when -DTRANSCRIBER_MACOS27 is set, and runs
# ONLY on a macOS 27 runtime (#available). The default build (A/B/C) stays on the current Xcode and the
# flag is OFF, so the shipped binary still runs on macOS 26 (text+OCR chat fallback). To compile D,
# point DEVELOPER_DIR at Xcode 27 beta and set MACOS27=1:
#   DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer MACOS27=1 Scripts/build_app.sh
SWIFT_FLAGS=()
if [[ "${MACOS27:-0}" == "1" ]]; then
    echo "==> Feature D: compiling the macOS-27 slide-image path (-DTRANSCRIBER_MACOS27)"
    SWIFT_FLAGS+=(-Xswiftc -DTRANSCRIBER_MACOS27)
fi

echo "==> Resolving + building ($CONFIG)…"
# (${arr[@]+...} guards empty-array expansion under `set -u` on bash 3.2.)
swift build -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
    echo "!! Build product not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Copy any SPM-generated resource bundles (e.g. KeyboardShortcuts localizations,
# WhisperKit assets) next to the app's resources so Bundle.module resolves them.
shopt -s nullglob
copied=0
for b in "$BIN_DIR"/*.bundle; do
    echo "    + $(basename "$b")"
    cp -R "$b" "$APP/Contents/Resources/"
    copied=$((copied+1))
done
[[ $copied -eq 0 ]] && echo "    (no resource bundles to copy)"

# Info.plist + PkgInfo
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon (generate with Scripts/make_icon.sh)
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc codesign. A stable bundle id + a code signature give the app a stable
# TCC identity so macOS remembers Microphone / Screen Recording grants across launches.
# Prefer a STABLE self-signed identity so TCC (Mic / Screen Recording) grants persist across
# rebuilds. Run Scripts/setup_signing.sh once to create it; otherwise fall back to ad-hoc
# (whose signature — and thus TCC identity — changes every build).
SIGN_IDENTITY="Transcriber Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "==> Codesigning with stable identity '$SIGN_IDENTITY'…"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
    echo "==> Codesigning ad-hoc (tip: run Scripts/setup_signing.sh for TCC-persistent signing)…"
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || true

# Strip any quarantine flag so a Finder double-click isn't blocked by Gatekeeper.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo ""
echo "==> Done: $APP"
echo "    Run:  open \"$APP\"     (or, to see logs:  \"$APP/Contents/MacOS/$APP_NAME\")"
