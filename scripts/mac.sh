#!/usr/bin/env bash
# Синхронизирует ~/capri на Мак и выполняет там команду.
# Использование: scripts/mac.sh "npm run test:macos"   |   scripts/mac.sh sync
set -euo pipefail
MAC=${CAPRI_MAC:-timomac}
DIR=${CAPRI_MAC_DIR:-capri}   # ~/capri на Маке
cd "$(dirname "$0")/.."
rsync -a --delete --exclude .git --exclude node_modules --exclude dist --exclude apps/macos/.build --exclude .DS_Store ./ "$MAC:$DIR/"
[[ ${1:-sync} == sync ]] && { echo "synced -> $MAC:~/$DIR"; exit 0; }
ssh -o BatchMode=yes "$MAC" "export PATH=\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH; cd ~/$DIR && $*"
