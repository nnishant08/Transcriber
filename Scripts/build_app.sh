#!/bin/bash
# Build Said and assemble a runnable, signed .app bundle.
# No Xcode required (uses Swift Package Manager + Command Line Tools).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Since the SaidKit split the SPM executable product IS "Said", so PRODUCT_NAME and APP_NAME
# finally agree. (SaidKit builds as a library alongside it; its resource bundle is copied below.)
PRODUCT_NAME="Said"
APP_NAME="Said"
CONFIG="${CONFIG:-release}"
APP="$ROOT/$APP_NAME.app"

# A dependency (KeyboardShortcuts) uses the SwiftUI #Preview macro, whose compiler
# plugin ships with full Xcode but NOT with the Command Line Tools. If Xcode is
# installed, point the build at it so the plugin resolves. (No sudo / xcode-select needed.)
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    echo "==> Using Xcode toolchain at $DEVELOPER_DIR"
fi

# TRANSCRIBER_MACOS27 is a build flag reserved for macOS-27-only SDK symbols. It is currently INERT —
# the multimodal slide-chat path that used it was removed along with the screenshot feature. Left in
# place because the next 27-only API (whatever it is) will want exactly this switch:
#   DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer MACOS27=1 Scripts/build_app.sh
SWIFT_FLAGS=()
if [[ "${MACOS27:-0}" == "1" ]]; then
    echo "==> Compiling with -DTRANSCRIBER_MACOS27 (macOS 27 SDK paths)"
    SWIFT_FLAGS+=(-Xswiftc -DTRANSCRIBER_MACOS27)
fi

echo "==> Resolving + building ($CONFIG)…"
# (${arr[@]+...} guards empty-array expansion under `set -u` on bash 3.2.)
swift build -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$PRODUCT_NAME"
if [[ ! -f "$BIN" ]]; then
    echo "!! Build product not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Copy any SPM-generated resource bundles next to the app's resources so Bundle.module resolves
# them. Since the split this includes SaidKit_SaidKit.bundle, which carries Packs/*.json — the
# `--selftest-packs` gate is what proves it was picked up.
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
SIGN_KEYCHAIN="$HOME/Library/Keychains/transcriber-signing.keychain-db"

# A REBOOT LOCKS THE KEYCHAIN, and a locked identity still appears in `find-identity` by name.
# Grepping for the name alone therefore reports success while codesign quietly falls back to an
# ad-hoc signature — whose designated requirement is a bare cdhash, which changes every build and
# silently invalidates the Microphone / Screen Recording grants this identity exists to preserve.
# Unlock first, then require a VALID identity, and say so loudly when there isn't one.
if [[ -f "$SIGN_KEYCHAIN" ]]; then
    security unlock-keychain -p "transcriber-local" "$SIGN_KEYCHAIN" 2>/dev/null || true
fi

if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "==> Codesigning with stable identity '$SIGN_IDENTITY'…"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
    echo "==> Codesigning ad-hoc (tip: run Scripts/setup_signing.sh for TCC-persistent signing)…"
    codesign --force --deep --sign - "$APP"
fi

# Verify what we actually got, rather than what we intended. A cdhash requirement means the
# signature is ad-hoc and TCC grants will NOT survive this rebuild.
REQ="$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)"
if [[ "$REQ" == *"cdhash"* ]]; then
    echo "!! WARNING: signed AD-HOC — TCC grants (Microphone / Screen Recording) will not persist."
    echo "!!   $REQ"
    echo "!!   Fix: security unlock-keychain \"$SIGN_KEYCHAIN\"   (or re-run Scripts/setup_signing.sh)"
else
    echo "    $REQ"
fi
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || true

# Strip any quarantine flag so a Finder double-click isn't blocked by Gatekeeper.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo ""
echo "==> Done: $APP"
echo "    Run:  open \"$APP\"     (or, to see logs:  \"$APP/Contents/MacOS/$APP_NAME\")"
