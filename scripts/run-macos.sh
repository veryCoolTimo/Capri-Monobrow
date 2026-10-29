#!/usr/bin/env bash
# Собрать, поставить в /Applications и запустить.
set -euo pipefail
exec bash "$(cd "$(dirname "$0")" && pwd)/install-macos.sh" "$@"
