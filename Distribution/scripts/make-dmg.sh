#!/usr/bin/env bash
# Build the Sentwise DMG with the branded background and drag-to-Applications
# layout.
#
# Home: Distribution/scripts/ — paths resolve relative to Distribution/.
# Requires: create-dmg  (brew install create-dmg; installed at
# /opt/homebrew/bin/create-dmg).
#
# Usage: make-dmg.sh <path-to.app> [output.dmg]
#   The .app should already be named "Sentwise.app" so the icon label under
#   the drag target reads as the brand name (the release pipeline stages it that
#   way). The exact geometry below matches the baked-in background art and must
#   not drift: 660x400 window, app icon at (160,214), Applications alias at
#   (500,214), 128px icons.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Sentwise.app}"
OUT="${2:-build/Sentwise.dmg}"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

if [[ ! -d "$APP" ]]; then
  echo "make-dmg: app not found: $APP" >&2
  exit 1
fi

# Window is 660x400; Finder draws the two 128px icons at the centers baked into
# the background art: app at (160,214), Applications alias at (500,214).
create-dmg \
  --volname "Sentwise" \
  --background "assets/png/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "$(basename "$APP")" 160 214 \
  --app-drop-link 500 214 \
  --hide-extension "$(basename "$APP")" \
  --no-internet-enable \
  "$OUT" "$APP"

echo "-> $OUT"
