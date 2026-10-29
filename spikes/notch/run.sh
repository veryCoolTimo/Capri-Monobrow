#!/usr/bin/env bash
# Собирает NotchSpike, заворачивает в .app и запускает. Запускать на Маке:
#   scripts/mac.sh "bash spikes/notch/run.sh [--expanded] [--no-notch] [--screen N]"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/swift-env.sh"
cd "$ROOT/apps/macos"
swift build -c release --product NotchSpike 2>&1 | tail -3
BIN="$(swift build -c release --show-bin-path)/NotchSpike"
APP="$ROOT/dist/NotchSpike.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NotchSpike"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NotchSpike</string>
<key>CFBundleIdentifier</key><string>local.capri.notchspike</string>
<key>CFBundleName</key><string>NotchSpike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
bash "$ROOT/scripts/stop-macos.sh"
rm -f /tmp/capri-notch.json*
open -n "$APP" --args "$@"
for _ in $(seq 1 20); do [ -f /tmp/capri-notch.json ] && break; sleep 0.25; done
cat /tmp/capri-notch.json
