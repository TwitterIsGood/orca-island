#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="universal"
CONFIGURATION="release"
usage() {
  cat <<'HELP'
Usage: ./scripts/build-companion.sh [--arch universal|native|arm64|x86_64] [--configuration release|debug]
Builds dist/OrcaIsland.app (default: Universal, Release, macOS 13+).
Existing app bundles are moved to dist/.backup-app-* before replacement.
Optional: ORCA_SIGNING_IDENTITY (Developer ID), ORCA_BUILD_NUMBER.
HELP
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch|--configuration) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; if [[ "$1" == "--arch" ]]; then ARCH="$2"; else CONFIGURATION="$2"; fi; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == "Darwin" ]] || { echo "Building requires macOS and Xcode Command Line Tools." >&2; exit 1; }
case "$ARCH" in universal) ARCHITECTURES=(arm64 x86_64) ;; native) ARCHITECTURES=("$(uname -m)") ;; arm64|x86_64) ARCHITECTURES=("$ARCH") ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;; esac
case "$CONFIGURATION" in release|debug) ;; *) echo "Unsupported configuration: $CONFIGURATION" >&2; exit 2 ;; esac
VERSION="$(/usr/bin/plutil -extract version raw -o - "$ROOT/orca-plugin.json")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Manifest version must be a stable x.y.z version: $VERSION" >&2; exit 1; }
BUILD_NUMBER="${ORCA_BUILD_NUMBER:-1}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "ORCA_BUILD_NUMBER must be numeric." >&2; exit 1; }
DIST="$ROOT/dist"
mkdir -p "$DIST"
STAGE="$(mktemp -d "$DIST/.stage-app.XXXXXX")"
APP="$STAGE/OrcaIsland.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BINARIES=()
for BUILD_ARCH in "${ARCHITECTURES[@]}"; do
  swift build --package-path "$ROOT/companion" --configuration "$CONFIGURATION" --arch "$BUILD_ARCH" --product OrcaIsland
  BIN_DIR="$(swift build --package-path "$ROOT/companion" --configuration "$CONFIGURATION" --arch "$BUILD_ARCH" --show-bin-path)"
  BINARIES+=("$BIN_DIR/OrcaIsland")
done
EXECUTABLE="$APP/Contents/MacOS/OrcaIsland"
if [[ ${#BINARIES[@]} -eq 2 ]]; then xcrun lipo -create "${BINARIES[@]}" -output "$EXECUTABLE"; else cp "${BINARIES[0]}" "$EXECUTABLE"; fi
chmod +x "$EXECUTABLE"
cp "$ROOT/scripts/orca-snapshot.cjs" "$ROOT/scripts/orca-projection.cjs" "$APP/Contents/Resources/"
xcrun lipo "$EXECUTABLE" -verify_arch "${ARCHITECTURES[@]}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Orca Island</string>
<key>CFBundleExecutable</key><string>OrcaIsland</string>
<key>CFBundleIdentifier</key><string>dev.orca.island</string>
<key>CFBundleName</key><string>Orca Island</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
SIGNING_IDENTITY="${ORCA_SIGNING_IDENTITY:--}"
SIGNING_OPTIONS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then SIGNING_OPTIONS+=(--options runtime --timestamp); fi
codesign "${SIGNING_OPTIONS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
if [[ -e "$DIST/OrcaIsland.app" ]]; then BACKUP="$(mktemp -d "$DIST/.backup-app.XXXXXX")"; mv "$DIST/OrcaIsland.app" "$BACKUP/OrcaIsland.app"; echo "Previous app retained at: $BACKUP/OrcaIsland.app"; fi
mv "$APP" "$DIST/OrcaIsland.app"
rmdir "$STAGE"
echo "$DIST/OrcaIsland.app"
