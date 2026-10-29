#!/usr/bin/env bash
# Собирает dist/Capri.app (значок, Info.plist, ad-hoc подпись). Установка — scripts/install-macos.sh.
set -euo pipefail
CAPRI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$CAPRI_ROOT/scripts/swift-env.sh"
ICON="$CAPRI_ROOT/apps/macos/Resources/AppIcon.icns"
if [[ ! -f "$ICON" ]]; then
  # Значок рисуется скриптом (своя стилизация) и хранится в репозитории (apps/macos/Resources);
  # пересоздать — удалить .icns и собрать.
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  swift "$CAPRI_ROOT/scripts/make-icon.swift" "$work/icon.png" >/dev/null
  mkdir -p "$work/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$work/icon.png" --out "$work/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$work/icon.png" --out "$work/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  mkdir -p "$(dirname "$ICON")"
  iconutil -c icns "$work/AppIcon.iconset" -o "$ICON"
  rm -rf "$work"
fi
cd "$CAPRI_ROOT/apps/macos"
swift build -c release --product Capri
CAPRI_BIN_DIR="$(swift build -c release --show-bin-path)"
CAPRI_APP="$CAPRI_ROOT/dist/Capri.app"
rm -rf "$CAPRI_ROOT/dist/Capri Prototype.app"
mkdir -p "$CAPRI_APP/Contents/MacOS" "$CAPRI_APP/Contents/Resources"
cp "$CAPRI_BIN_DIR/Capri" "$CAPRI_APP/Contents/MacOS/Capri"
cp "$ICON" "$CAPRI_APP/Contents/Resources/AppIcon.icns"
# Keep the .app root sealed; the asset loader also supports a direct SwiftPM run.
rm -rf "$CAPRI_APP/Capri_Capri.bundle"
ditto "$CAPRI_BIN_DIR/Capri_Capri.bundle" "$CAPRI_APP/Contents/Resources/Capri_Capri.bundle"
cat > "$CAPRI_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Capri</string>
<key>CFBundleIdentifier</key><string>local.capri</string>
<key>CFBundleName</key><string>Capri</string>
<key>CFBundleDisplayName</key><string>Capri</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$CAPRI_APP"
codesign --verify --deep --strict "$CAPRI_APP"
echo "$CAPRI_APP"
