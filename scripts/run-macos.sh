#!/usr/bin/env bash
set -euo pipefail
CAPRI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -d "$CAPRI_ROOT/dist/Capri Prototype.app" ]]; then
  bash "$CAPRI_ROOT/scripts/build-macos.sh"
fi
bash "$CAPRI_ROOT/scripts/stop-macos.sh"
open "$CAPRI_ROOT/dist/Capri Prototype.app"
