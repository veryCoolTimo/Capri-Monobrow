#!/usr/bin/env bash
set -euo pipefail
CAPRI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$CAPRI_ROOT/scripts/swift-env.sh"
cd "$CAPRI_ROOT/apps/macos"
swift build -c release --product Capri
CAPRI_BIN_DIR="$(swift build -c release --show-bin-path)"
CAPRI_APP="$CAPRI_ROOT/dist/Capri Prototype.app"
mkdir -p "$CAPRI_APP/Contents/MacOS" "$CAPRI_APP/Contents/Resources"
cp "$CAPRI_BIN_DIR/Capri" "$CAPRI_APP/Contents/MacOS/Capri"
# Keep the .app root sealed; the asset loader also supports a direct SwiftPM run.
rm -rf "$CAPRI_APP/Capri_Capri.bundle"
ditto "$CAPRI_BIN_DIR/Capri_Capri.bundle" "$CAPRI_APP/Contents/Resources/Capri_Capri.bundle"
cat > "$CAPRI_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Capri</string>
<key>CFBundleIdentifier</key><string>local.capri.prototype</string>
<key>CFBundleName</key><string>Capri Prototype</string>
<key>CFBundleDisplayName</key><string>Capri</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$CAPRI_APP"
codesign --verify --deep --strict "$CAPRI_APP"
echo "$CAPRI_APP"
