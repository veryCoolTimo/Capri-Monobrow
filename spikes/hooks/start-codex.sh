#!/bin/bash
# Codex TUI для спайка: проектные хуки из ./.codex/hooks.json без записи доверия в конфиг,
# notify подменён только на этот запуск (-c), ~/.codex/config.toml не меняется.
cd "$HOME/capri-test-hooks"
codex --dangerously-bypass-hook-trust -a on-request -s read-only \
  -c "notify=[\"python3\",\"$HOME/capri-test-hooks/record.py\",\"codex:notify\"]" "$@"
echo "codex exited: $?"; sleep 600
