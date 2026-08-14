#!/usr/bin/env bash
# Build AppIcon.icns from the icon masters.
#
# Home: Distribution/scripts/ — paths resolve relative to Distribution/.
# Requires macOS (sips + iconutil). Optional: rsvg-convert for a re-render from
# the SVG masters (sharper than downscaling); otherwise sips downscales the
# checked-in PNG sources. The app itself ships its icon from the asset catalog
# (AppIcon.appiconset) — this .icns is only for ancillary uses (e.g. a DMG
# volume icon).
set -euo pipefail
cd "$(dirname "$0")/.."

LARGE_SVG="assets/Sentwise.svg"
SMALL_SVG="assets/Sentwise-small.svg"
LARGE_SRC="assets/png/icon_1024.png"
SMALL_SRC="../Sentwise/Sentwise/Resources/Assets.xcassets/AppIcon.appiconset/icon_32x32.png"
OUT="build/AppIcon.iconset"
mkdir -p "$OUT" build

# Physical 16px and 32px outputs use the hand-tuned small master; larger outputs
# use the full icon. If librsvg is unavailable, preserve that same split by
# downscaling the checked-in 32px app-icon slot for small outputs.
render() { # $1 = px, $2 = dest
  local svg="$LARGE_SVG"
  local src="$LARGE_SRC"
  if [[ "$1" -le 32 ]]; then
    svg="$SMALL_SVG"
    src="$SMALL_SRC"
  fi

  if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w "$1" -h "$1" "$svg" -o "$2"
  else
    sips -z "$1" "$1" "$src" --out "$2" >/dev/null
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
