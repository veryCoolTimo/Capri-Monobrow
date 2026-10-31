#!/usr/bin/env bash
# Контактные листы сцен персонажа без записи экрана: Capri на Маке рендерит кадры сцены в сетку
# (`scene sheet`), скрипт забирает их в work/previews/ (не в репозитории).
# Capri должен быть запущен с --debug-control:
#   open -a /Applications/Capri.app --args --background --debug-control
# Использование: scripts/scene-frames.sh teleport teleport:window window takeover:terminal vibe \
#   sessions sessions:hover sessions:busy thinking answer answer:sent reply reply:fail reply:corner music music:fail music:search \
#   teleport:controls
set -euo pipefail
MAC=${CAPRI_MAC:-timomac}
cd "$(dirname "$0")/.."
OUT=${CAPRI_PREVIEWS:-work/previews}
mkdir -p "$OUT"
for spec in "${@:-teleport}"; do
  kind=${spec%%:*}; variant=""
  [[ $spec == *:* ]] && variant=${spec#*:}
  # Аргументы уходят в команду на Маке — только буквы.
  [[ $kind =~ ^[a-z]+$ && $variant =~ ^[a-z]*$ ]] || { echo "плохая сцена: $spec" >&2; exit 1; }
  name=$kind${variant:+-$variant}
  ssh -o BatchMode=yes "$MAC" "rm -f ~/.capri/tmp/scene-$name.png ~/.capri/tmp/scene-$name-detail.png; echo 'scene sheet $kind $variant' > ~/.capri/tmp/control"
  ok=""
  for _ in $(seq 1 40); do
    if ssh -o BatchMode=yes "$MAC" "test -f ~/.capri/tmp/scene-$name-detail.png"; then ok=1; break; fi
    sleep 0.5
  done
  [[ -n $ok ]] || { echo "нет листа $name (Capri запущен с --debug-control?)" >&2; exit 1; }
  scp -q "$MAC:.capri/tmp/scene-$name.png" "$MAC:.capri/tmp/scene-$name-detail.png" "$OUT/"
  echo "$OUT/scene-$name.png $OUT/scene-$name-detail.png"
done
