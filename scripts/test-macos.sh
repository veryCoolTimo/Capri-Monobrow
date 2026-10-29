#!/usr/bin/env bash
set -euo pipefail
CAPRI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$CAPRI_ROOT/scripts/swift-env.sh"
cd "$CAPRI_ROOT/apps/macos"
swift test
