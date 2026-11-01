#!/usr/bin/env bash
# Лист мини-маски (риг) без записи экрана: Capri на Маке рисует все выражения, позы и кадры моментов
# (`rig sheet`), скрипт забирает их в work/previews/ (не в репозитории).
# Локальный рисунок «по мотивам» (work/art/capri-rig.json, не в git) перед этим копируется в ~/.capri/art на Маке;
# без него Capri рисует простой фолбэк из кода.
# Capri должен быть запущен с --debug-control:
#   open -a /Applications/Capri.app --args --background --debug-control
set -euo pipefail
MAC=${CAPRI_MAC:-timomac}
cd "$(dirname "$0")/.."
OUT=${CAPRI_PREVIEWS:-work/previews}
ART=${CAPRI_RIG_ART:-work/art/capri-rig.json}
mkdir -p "$OUT"
if [[ -f $ART ]]; then
  ssh -o BatchMode=yes "$MAC" "mkdir -p ~/.capri/art"
  scp -q "$ART" "$MAC:.capri/art/capri-rig.json"
fi
ssh -o BatchMode=yes "$MAC" "rm -f ~/.capri/tmp/rig-sheet.png ~/.capri/tmp/rig-moments.png ~/.capri/tmp/rig-scales.png; echo 'rig sheet' > ~/.capri/tmp/control"
ok=""
for _ in $(seq 1 40); do
  if ssh -o BatchMode=yes "$MAC" "test -f ~/.capri/tmp/rig-scales.png"; then ok=1; break; fi
  sleep 0.5
done
[[ -n $ok ]] || { echo "нет листа рига (Capri запущен с --debug-control?)" >&2; exit 1; }
scp -q "$MAC:.capri/tmp/rig-sheet.png" "$MAC:.capri/tmp/rig-moments.png" "$MAC:.capri/tmp/rig-scales.png" "$OUT/"
echo "$OUT/rig-sheet.png $OUT/rig-moments.png $OUT/rig-scales.png"
