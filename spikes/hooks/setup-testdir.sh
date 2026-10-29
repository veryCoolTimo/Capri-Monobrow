#!/usr/bin/env bash
# Создаёт ~/capri-test-hooks: рекордер, настройки Claude (через --settings) и проектные хуки Codex.
# Глобальные ~/.claude/settings.json и ~/.codex/* не трогает.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
D="$HOME/capri-test-hooks"
mkdir -p "$D/.codex"
cp "$SRC/record.py" "$D/record.py"
cp "$SRC/claude-settings.json" "$D/claude-settings.json"
cp "$SRC/start-codex.sh" "$D/start-codex.sh"
cp "$SRC/codex-hooks.json" "$D/.codex/hooks.json"
[ -f "$D/events.jsonl" ] || : > "$D/events.jsonl"
cd "$D" && { [ -d .git ] || git init -q; }
echo "$D ready"
