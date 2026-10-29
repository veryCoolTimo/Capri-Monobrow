#!/usr/bin/env bash
# Останавливает все запущенные сборки Capri на Маке: scripts/mac.sh "bash scripts/stop-macos.sh"
for name in NotchSpike Capri; do  # Capri.app и старая Capri Prototype.app — один процесс Capri
  if pkill -x "$name" 2>/dev/null; then
    for _ in $(seq 1 20); do pgrep -x "$name" >/dev/null || break; sleep 0.1; done
    pkill -9 -x "$name" 2>/dev/null || true
    echo "stopped $name"
  fi
done
exit 0
