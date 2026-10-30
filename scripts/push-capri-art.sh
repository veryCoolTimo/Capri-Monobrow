#!/usr/bin/env bash
# Кладёт клипы сериала с глазами Capri на Мак в ~/.capri/art/eyes (их берёт ShowArt). Кадры сериала — только
# локально: в публичный репозиторий не входят. Без них Capri показывает встроенные кадры.
# Использование: scripts/push-capri-art.sh [папка с clips.json и NNN.png]   (по умолчанию work/art/show/eyes)
set -euo pipefail
MAC=${CAPRI_MAC:-timomac}
SRC=$(cd "${1:-$(dirname "$0")/../work/art/show/eyes}" && pwd)
cd "$(dirname "$0")/.."
[[ -f $SRC/clips.json ]] || { echo "нет $SRC/clips.json" >&2; exit 1; }
ssh -o BatchMode=yes "$MAC" "mkdir -p ~/.capri/art/eyes"
rsync -a --delete --include 'clips.json' --include '*.png' --exclude '*' "$SRC/" "$MAC:.capri/art/eyes/"
echo "art -> $MAC:~/.capri/art/eyes ($(ls "$SRC"/*.png | wc -l) кадров)"
