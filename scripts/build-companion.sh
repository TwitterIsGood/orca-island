#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build -c release --package-path "$ROOT/companion"
BIN_DIR="$(swift build -c release --package-path "$ROOT/companion" --show-bin-path)"
APP="$ROOT/dist/OrcaIsland.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OrcaIsland" "$APP/Contents/MacOS/OrcaIsland"
chmod +x "$APP/Contents/MacOS/OrcaIsland"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Orca Island</string>
    <key>CFBundleExecutable</key>
    <string>OrcaIsland</string>
    <key>CFBundleIdentifier</key>
    <string>dev.orca.island</string>
    <key>CFBundleName</key>
    <string>Orca Island</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
