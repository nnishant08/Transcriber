#!/bin/bash
# Generate Resources/AppIcon.icns from Scripts/GenerateIcon.swift.
#
# Every size is rendered NATIVELY rather than downscaled from 1024 — the mark is
# specified as ratios, so a 16px render is a real 16px drawing instead of a blurred
# resample. This is what keeps the small Finder/list-view sizes crisp.
#
# Shape knobs (override per invocation):
#   SHAPE=doc|comma   REACH=<bowl radii>   ANGLE=<degrees>   VARIANT=violet|ink|paper
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

SHAPE="${SHAPE:-doc}"
REACH="${REACH:-1.62}"
ANGLE="${ANGLE:-225}"
VARIANT="${VARIANT:-violet}"

TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> Rendering ladder natively (shape=$SHAPE variant=$VARIANT)…"
for s in 16 32 64 128 256 512 1024; do
    swift Scripts/GenerateIcon.swift "$TMP/$s.png" \
        --size "$s" --variant "$VARIANT" --shape "$SHAPE" --reach "$REACH" --angle "$ANGLE" >/dev/null
done

# icns wants each logical size at 1x and 2x; both come from the matching native render.
cp "$TMP/16.png"   "$ICONSET/icon_16x16.png"
cp "$TMP/32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$TMP/32.png"   "$ICONSET/icon_32x32.png"
cp "$TMP/64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$TMP/128.png"  "$ICONSET/icon_128x128.png"
cp "$TMP/256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$TMP/256.png"  "$ICONSET/icon_256x256.png"
cp "$TMP/512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$TMP/512.png"  "$ICONSET/icon_512x512.png"
cp "$TMP/1024.png" "$ICONSET/icon_512x512@2x.png"

mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "==> Wrote Resources/AppIcon.icns"
