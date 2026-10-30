#!/usr/bin/env bash
# Собирает и ставит Capri.app в /Applications (если нет прав — в ~/Applications), регистрирует
# в Launch Services (Launchpad, Spotlight) и запускает в фоне — без окна (окно не должно само вылезать,
# например поверх полноэкранного приложения). --no-open — только поставить, --show — запустить с окном.
set -euo pipefail
CAPRI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$CAPRI_ROOT/scripts/build-macos.sh" >/dev/null
DEST=/Applications
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"
bash "$CAPRI_ROOT/scripts/stop-macos.sh"
rm -rf "$DEST/Capri.app.new"
ditto "$CAPRI_ROOT/dist/Capri.app" "$DEST/Capri.app.new"
rm -rf "$DEST/Capri.app"
mv "$DEST/Capri.app.new" "$DEST/Capri.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Старые сборки из dist не должны всплывать в Spotlight рядом с установленной.
"$LSREG" -u "$CAPRI_ROOT/dist/Capri Prototype.app" 2>/dev/null || true
"$LSREG" -u "$CAPRI_ROOT/dist/Capri.app" 2>/dev/null || true
"$LSREG" -u "$CAPRI_ROOT/dist/NotchSpike.app" 2>/dev/null || true
rm -rf "$CAPRI_ROOT/dist/Capri.app" "$CAPRI_ROOT/dist/NotchSpike.app"
"$LSREG" -f "$DEST/Capri.app"
echo "$DEST/Capri.app"
case "${1:-}" in
  --no-open) ;;
  --show) open "$DEST/Capri.app" ;;
  *) open "$DEST/Capri.app" --args --background ;;
esac
