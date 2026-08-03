#!/usr/bin/env bash
# Build AppIcon.icns from the 1024 master PNG.
#
# Home: Distribution/scripts/ — paths resolve relative to Distribution/.
# Requires macOS (sips + iconutil). Optional: rsvg-convert for a re-render from
# the SVG master (sharper than downscaling); it is NOT installed on this machine,
# so the sips fallback is the live path. The app itself ships its icon from the
# asset catalog (AppIcon.appiconset) — this .icns is only for ancillary uses
# (e.g. a DMG volume icon).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="assets/png/icon_1024.png"
OUT="build/AppIcon.iconset"
mkdir -p "$OUT" build

# Re-render from the SVG master if librsvg is available (sharper than downscaling).
render() { # $1 = px, $2 = dest
  if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w "$1" -h "$1" assets/EmailJunkie.svg -o "$2"
  else
    sips -z "$1" "$1" "$SRC" --out "$2" >/dev/null
  fi
}

render 16   "$OUT/icon_16x16.png"
render 32   "$OUT/icon_16x16@2x.png"
render 32   "$OUT/icon_32x32.png"
render 64   "$OUT/icon_32x32@2x.png"
render 128  "$OUT/icon_128x128.png"
render 256  "$OUT/icon_128x128@2x.png"
render 256  "$OUT/icon_256x256.png"
render 512  "$OUT/icon_256x256@2x.png"
render 512  "$OUT/icon_512x512.png"
render 1024 "$OUT/icon_512x512@2x.png"

iconutil -c icns "$OUT" -o build/AppIcon.icns
echo "-> Distribution/build/AppIcon.icns"
