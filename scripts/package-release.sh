#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD=true
case "${1:-}" in "") ;; --skip-build) BUILD=false ;; -h|--help) echo "Usage: ./scripts/package-release.sh [--skip-build]"; echo "Builds Universal Release and produces ZIP, DMG, and SHA256SUMS in dist/."; echo "Optional: ORCA_SIGNING_IDENTITY, ORCA_NOTARY_PROFILE (stored keychain credentials)."; exit 0 ;; *) echo "Unknown argument: $1" >&2; exit 2 ;; esac
[[ $# -le 1 ]] || { echo "Expected at most one argument." >&2; exit 2; }
if [[ "$BUILD" == true ]]; then "$ROOT/scripts/build-companion.sh" --arch universal --configuration release; fi
DIST="$ROOT/dist"; APP="$DIST/OrcaIsland.app"; VERSION="$(/usr/bin/plutil -extract version raw -o - "$ROOT/orca-plugin.json")"; APP_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
[[ "$VERSION" == "$APP_VERSION" ]] || { echo "App version $APP_VERSION differs from manifest $VERSION; rebuild first." >&2; exit 1; }
xcrun lipo "$APP/Contents/MacOS/OrcaIsland" -verify_arch arm64 x86_64; codesign --verify --deep --strict "$APP"
STAGE="$(mktemp -d "$DIST/.stage-package.XXXXXX")"; ZIP_NAME="OrcaIsland-macos-universal.zip"; DMG_NAME="OrcaIsland-macos-universal.dmg"; ZIP="$STAGE/$ZIP_NAME"; DMG="$STAGE/$DMG_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [[ -n "${ORCA_NOTARY_PROFILE:-}" ]]; then
  [[ -n "${ORCA_SIGNING_IDENTITY:-}" && "$ORCA_SIGNING_IDENTITY" != "-" ]] || { echo "Notarization requires a Developer ID signing identity." >&2; exit 1; }
  xcrun notarytool submit "$ZIP" --keychain-profile "$ORCA_NOTARY_PROFILE" --wait; xcrun stapler staple "$APP"; xcrun stapler validate "$APP"; mv "$ZIP" "$STAGE/pre-notarization.zip"; ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi
mkdir "$STAGE/dmg-root"; ditto "$APP" "$STAGE/dmg-root/OrcaIsland.app"; ln -s /Applications "$STAGE/dmg-root/Applications"; hdiutil create -volname "Orca Island $VERSION" -srcfolder "$STAGE/dmg-root" -ov -format UDZO "$DMG"
if [[ -n "${ORCA_SIGNING_IDENTITY:-}" && "$ORCA_SIGNING_IDENTITY" != "-" ]]; then codesign --force --sign "$ORCA_SIGNING_IDENTITY" --timestamp "$DMG"; fi
if [[ -n "${ORCA_NOTARY_PROFILE:-}" ]]; then xcrun notarytool submit "$DMG" --keychain-profile "$ORCA_NOTARY_PROFILE" --wait; xcrun stapler staple "$DMG"; xcrun stapler validate "$DMG"; fi
hdiutil verify "$DMG"
mkdir "$STAGE/unpacked"; ditto -x -k "$ZIP" "$STAGE/unpacked"; codesign --verify --deep --strict "$STAGE/unpacked/OrcaIsland.app"; xcrun lipo "$STAGE/unpacked/OrcaIsland.app/Contents/MacOS/OrcaIsland" -verify_arch arm64 x86_64
(cd "$STAGE"; shasum -a 256 "$ZIP_NAME" "$DMG_NAME" > SHA256SUMS; shasum -a 256 -c SHA256SUMS)
BACKUP=""; for FILE in "$ZIP_NAME" "$DMG_NAME" SHA256SUMS; do if [[ -e "$DIST/$FILE" ]]; then if [[ -z "$BACKUP" ]]; then BACKUP="$(mktemp -d "$DIST/.backup-release.XXXXXX")"; fi; mv "$DIST/$FILE" "$BACKUP/$FILE"; fi; mv "$STAGE/$FILE" "$DIST/$FILE"; done
echo "Release $VERSION:"; echo "  $DIST/$ZIP_NAME"; echo "  $DIST/$DMG_NAME"; echo "  $DIST/SHA256SUMS"; echo "Verification files retained at: $STAGE"
