#!/usr/bin/env bash
# Замер Capri в простое (критерий MVP: <1% CPU, <150 МБ). Запускать на Маке, когда Capri уже работает:
#   bash scripts/measure-macos.sh [минут=5]
# Ничего не запускает и не трогает: раз в 10 с читает CPU и память процесса Capri (и его codex/ssh-детей)
# через ps и «энергетическое влияние» через top. Итог — средние и максимумы.
set -euo pipefail
# Десятичная точка в ps/bc/printf при любой локали.
export LC_ALL=C
MINUTES="${1:-5}"
PID="$(pgrep -x Capri | head -1 || true)"
[[ -n "$PID" ]] || { echo "Capri не запущен"; exit 1; }
SAMPLES=$((MINUTES * 6))
echo "Capri pid $PID · $MINUTES мин · $SAMPLES замеров"
cpu_sum=0; cpu_max=0; rss_max=0; kids_rss_max=0; power_sum=0; n=0
for _ in $(seq 1 "$SAMPLES"); do
  line="$(ps -o %cpu=,rss= -p "$PID" || true)"
  [[ -n "$line" ]] || { echo "Capri завершился во время замера"; break; }
  read -r cpu rss <<<"$line"
  # Все потомки (ssh-сборщики, codex app-server и его дети), а не только прямые.
  kids_rss=$(ps -A -o pid=,ppid=,rss= | awk -v root="$PID" '
    { parent[$1] = $2; mem[$1] = $3 }
    END { for (p in parent) { q = parent[p]; while (q != "" && q != 0 && q != root) q = parent[q]; if (q == root) s += mem[p] } print s + 0 }')
  power=$(top -l 2 -s 1 -pid "$PID" -stats power 2>/dev/null | tail -1 | awk '{print $1+0}' || echo 0)
  cpu_sum=$(echo "$cpu_sum + $cpu" | bc); n=$((n + 1))
  power_sum=$(echo "$power_sum + $power" | bc)
  (( $(echo "$cpu > $cpu_max" | bc) )) && cpu_max=$cpu
  (( rss > rss_max )) && rss_max=$rss
  (( kids_rss > kids_rss_max )) && kids_rss_max=$kids_rss
  sleep 8
done
(( n > 0 )) || { echo "нет замеров"; exit 1; }
printf 'CPU: среднее %.2f%%, максимум %.1f%%\n' "$(echo "$cpu_sum / $n" | bc -l)" "$cpu_max"
printf 'Память Capri: максимум %d МБ; дочерние (ssh, codex): максимум %d МБ\n' $((rss_max / 1024)) $((kids_rss_max / 1024))
printf 'Энергетическое влияние (top power): среднее %.1f\n' "$(echo "$power_sum / $n" | bc -l)"
