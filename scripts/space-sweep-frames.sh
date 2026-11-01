#!/usr/bin/env bash
# Лист кадров «глаза уезжают со сменой пространства» без записи экрана: Capri на Маке рисует эффект офскрин
# (`sweep sheet`), скрипт забирает его в work/previews/ (не в репозитории).
# Capri должен быть запущен с --debug-control:
#   open -a /Applications/Capri.app --args --background --debug-control
# Использование: scripts/space-sweep-frames.sh [alert]   (alert — «тебя ждут», много глаз)
set -euo pipefail
MAC=${CAPRI_MAC:-timomac}
cd "$(dirname "$0")/.."
OUT=${CAPRI_PREVIEWS:-work/previews}
mkdir -p "$OUT"
variant=${1:-}
[[ -z $variant || $variant == alert ]] || { echo "плохой вариант: $variant" >&2; exit 1; }
ssh -o BatchMode=yes "$MAC" "rm -f ~/.capri/tmp/space-sweep.png; echo 'sweep sheet $variant' > ~/.capri/tmp/control"
ok=""
for _ in $(seq 1 40); do
  if ssh -o BatchMode=yes "$MAC" "test -f ~/.capri/tmp/space-sweep.png"; then ok=1; break; fi
  sleep 0.5
done
[[ -n $ok ]] || { echo "нет листа (Capri запущен с --debug-control?)" >&2; exit 1; }
name=space-sweep${variant:+-$variant}.png
scp -q "$MAC:.capri/tmp/space-sweep.png" "$OUT/$name"
echo "$OUT/$name"
