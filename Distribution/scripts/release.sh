#!/usr/bin/env bash
#
# Email Junkie release pipeline.
#
#   archive -> export (Developer ID) -> notarize -> DMG -> appcast -> checksums
#
# Everything credential-related comes from the environment (nothing is
# hardcoded or stored in the repo). A --dry-run mode exercises the whole
# archive -> DMG path WITHOUT any credentials so the pipeline is testable now.
#
# Full runbook and prerequisites: docs/releasing.md
#
# Usage:
#   release.sh --dry-run [--version X.Y.Z] [--build N]
#   release.sh [--version X.Y.Z] [--build N]        # full signed release
#
# Environment (required for a full signed release, ignored by --dry-run):
#   SIGNING_IDENTITY   Developer ID Application identity, e.g.
#                      "Developer ID Application: Your Name (TEAMID)"
#   DEVELOPMENT_TEAM   10-char Apple Developer Team ID
#   NOTARY_PROFILE     notarytool keychain profile name (see releasing.md)
# Optional:
#   SPARKLE_BIN        directory holding Sparkle's generate_appcast / sign_update
#                      (defaults to searching PATH). Needed for the appcast step.
#
set -euo pipefail

# ---- paths -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"            # Distribution/
REPO_ROOT="$(cd "$DIST_DIR/.." && pwd)"
PROJECT="$REPO_ROOT/EmailJunkie/EmailJunkie.xcodeproj"
SCHEME="EmailJunkie"
APP_DISPLAY_NAME="Email Junkie"                     # DMG icon label / volume name
OUT="$REPO_ROOT/dist"                               # gitignored artifact dir

# ---- args ------------------------------------------------------------------
DRY_RUN=0
VERSION=""
BUILD=""

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    --build)   BUILD="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "release: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

pbxproj="$PROJECT/project.pbxproj"
[[ -z "$VERSION" ]] && VERSION="$(grep -m1 'MARKETING_VERSION = ' "$pbxproj" | sed 's/.*= //; s/;.*//')"
[[ -z "$BUILD"   ]] && BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$pbxproj" | sed 's/.*= //; s/;.*//')"

log()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m### %s\033[0m\n' "$*"; }

ARCHIVE="$OUT/EmailJunkie.xcarchive"
EXPORT_DIR="$OUT/export"
STAGE_DIR="$OUT/stage"
DMG="$OUT/EmailJunkie-$VERSION.dmg"

# The all-zero SUPublicEDKey placeholder shipped in Info.plist until a real
# EdDSA keypair is generated at release time. Shipping a signed build with this
# key silently breaks auto-update (the app would verify against a degenerate
# zero key while generate_appcast signs with the real private key), so the
# signed path hard-aborts if the built app still carries it.
PLACEHOLDER_EDKEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

step "Email Junkie release  (version $VERSION, build $BUILD, dry-run=$DRY_RUN)"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$STAGE_DIR"
mkdir -p "$OUT"

# ---- credential pre-flight (signed only) -----------------------------------
if [[ "$DRY_RUN" -eq 0 ]]; then
  : "${SIGNING_IDENTITY:?set SIGNING_IDENTITY (Developer ID Application: …)}"
  : "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM (Apple Team ID)}"
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile)}"
fi

# ---- 1. archive ------------------------------------------------------------
step "1/6  Archiving Release"
if [[ "$DRY_RUN" -eq 1 ]]; then
  xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGNING_ALLOWED=NO
else
  xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
fi

# ---- 2. export a distributable .app ----------------------------------------
step "2/6  Exporting app bundle"
mkdir -p "$EXPORT_DIR"
if [[ "$DRY_RUN" -eq 1 ]]; then
  # No signing: lift the .app straight out of the archive.
  cp -R "$ARCHIVE/Products/Applications/EmailJunkie.app" "$EXPORT_DIR/EmailJunkie.app"
else
  cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$EXPORT_DIR"
fi

# ---- 2b. guard the update-signing key --------------------------------------
# Validate what actually SHIPS (the built app's merged Info.plist), not the
# source plist. A signed release with the placeholder key would install fine
# but never accept an update, so this is a hard stop for real releases.
built_edkey="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
  "$EXPORT_DIR/EmailJunkie.app/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$built_edkey" == "$PLACEHOLDER_EDKEY" || -z "$built_edkey" ]]; then
    log "NOTE: SUPublicEDKey is the placeholder — expected for a dry run; a real signed release would abort here."
  fi
else
  if [[ -z "$built_edkey" || "$built_edkey" == "$PLACEHOLDER_EDKEY" ]]; then
    echo "release: SUPublicEDKey is still the placeholder (or empty/missing) in the built app." >&2
    echo "         Run Sparkle's generate_keys and paste the real public key into" >&2
    echo "         EmailJunkie/Info.plist, then rebuild. See docs/releasing.md." >&2
    exit 1
  fi
  log "SUPublicEDKey verified present (non-placeholder)"
fi

# ---- 3. stage under the branded name ---------------------------------------
step "3/6  Staging \"$APP_DISPLAY_NAME.app\""
mkdir -p "$STAGE_DIR"
cp -R "$EXPORT_DIR/EmailJunkie.app" "$STAGE_DIR/$APP_DISPLAY_NAME.app"

# ---- 4. build the DMG ------------------------------------------------------
step "4/6  Building DMG"
"$SCRIPT_DIR/make-dmg.sh" "$STAGE_DIR/$APP_DISPLAY_NAME.app" "$DMG"

# ---- 5. notarize + staple (signed only) ------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  step "5/6  Notarize — SKIPPED (dry-run)"
else
  step "5/6  Notarizing DMG (notarytool submit --wait)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  log "Stapling ticket"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

# ---- 6. appcast + checksums ------------------------------------------------
step "6/6  Appcast + checksums"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Appcast — SKIPPED (dry-run; needs the EdDSA private key)"
else
  gen_appcast="$(command -v generate_appcast || true)"
  [[ -z "$gen_appcast" && -n "${SPARKLE_BIN:-}" ]] && gen_appcast="$SPARKLE_BIN/generate_appcast"
  if [[ -z "$gen_appcast" || ! -x "$gen_appcast" ]]; then
    echo "release: generate_appcast not found. Set SPARKLE_BIN to Sparkle's bin dir." >&2
    exit 1
  fi
  # generate_appcast signs every archive in $OUT with the private key from the
  # Keychain and (re)writes appcast.xml alongside them.
  "$gen_appcast" "$OUT"
  log "Wrote $OUT/appcast.xml"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"

step "Done"
log "DMG:       $DMG"
[[ "$DRY_RUN" -eq 0 ]] && log "Appcast:   $OUT/appcast.xml"
log "Checksums: $DMG.sha256"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  log "Dry run complete — unsigned, un-notarized artifact for layout testing only."
fi
