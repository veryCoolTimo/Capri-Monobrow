#!/usr/bin/env bash
# Установка хуков Capri на хост. По умолчанию — только показать, что изменится.
#   scripts/install-hooks.sh <mac|timoserver|quiz> [--dry-run | --apply | --uninstall] [опции capri-hook]
# --dry-run: capri-hook передаётся в python через stdin, на хосте ничего не пишется.
# --apply:   копирует capri-hook в ~/.capri/bin и сливает хуки (бэкап рядом с каждым файлом).
# --uninstall: убирает только записи capri-hook, исходный notify Codex возвращается.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/tools/capri-hook/capri-hook"
TARGET=${1:?хост: mac | timoserver | quiz}
MODE=${2:---dry-run}
shift $(( $# >= 2 ? 2 : 1 ))
# Доп. опции capri-hook — каждая в кавычках для удалённой оболочки.
EXTRA=""
for a in "$@"; do EXTRA+=" $(printf '%q' "$a")"; done

# Как попасть на хост отсюда (timoserver): quiz доступен только через Мак.
case "$TARGET" in
  timoserver) run() { bash -lc "$1"; } ;;
  mac)        run() { ssh -o BatchMode=yes timomac "export PATH=\$HOME/.local/bin:/opt/homebrew/bin:\$PATH; $1"; } ;;
  quiz)       run() { ssh -o BatchMode=yes timomac "ssh -o BatchMode=yes quiz $(printf '%q' "export PATH=\$HOME/.local/bin:\$PATH; $1")"; } ;;
  *) echo "неизвестный хост $TARGET" >&2; exit 2 ;;
esac

case "$MODE" in
  --dry-run)   run "python3 - install --dry-run$EXTRA" < "$HOOK" ;;
  --apply)
    run 'mkdir -p ~/.capri/bin && cat > ~/.capri/bin/capri-hook.new && chmod 755 ~/.capri/bin/capri-hook.new && mv ~/.capri/bin/capri-hook.new ~/.capri/bin/capri-hook' < "$HOOK"
    run "python3 ~/.capri/bin/capri-hook install$EXTRA" ;;
  --uninstall) run "python3 ~/.capri/bin/capri-hook uninstall$EXTRA" ;;
  --status)    run "python3 ~/.capri/bin/capri-hook status" ;;
  *) echo "режим: --dry-run | --apply | --uninstall | --status" >&2; exit 2 ;;
esac
