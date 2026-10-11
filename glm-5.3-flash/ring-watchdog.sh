#!/usr/bin/env bash
# ring-watchdog.sh <pipeline pid> — guard for ring-pipeline.sh (2026-10-11). Expires after 3 h. If the pipeline dies
# without a final line, or makes no progress for 60 min, it stops the ring containers and restarts the preserved LVKP
# containers (r3 -> r0). Never touches the fabric or model files. A node failing ssh 3 times is logged as CRITICAL.
set -uo pipefail
G="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; L=$G/logs/ring; S=$L/STATUS
PID=${1:?pid}; END=$(( $(date +%s) + 3*3600 )); STALL=$(( 60*60 ))
NODES=(local spark1 spark2 spark4); declare -A miss=([spark1]=0 [spark2]=0 [spark4]=0)
note() { echo "$(date -Is) [watchdog] $*" | tee -a $S; }
on() { local n=$1; shift; if [ "$n" = local ]; then bash -c "$*"; else ssh -o BatchMode=yes -o ConnectTimeout=15 "$n" "$*"; fi; }
final() { grep -qE 'RING KEPT|ROLLED BACK|ROLLBACK FAILED' $S; }
restore() {
  note "restore LVKP (reason: $1)"
  for r in 3 2 1 0; do on ${NODES[$r]} "docker stop glm53-ring-r$r >/dev/null 2>&1; docker rm -f glm-ring-smoke-r$r >/dev/null 2>&1; true"; done; sleep 10
  for r in 3 2 1 0; do on ${NODES[$r]} "docker start glm53-switchless-r$r" >> $L/watchdog-restore.log 2>&1; sleep 3; done
  for i in $(seq 1 80); do
    curl -fsS -m 300 http://127.0.0.1:8100/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"glm-5.3-flash","temperature":0,"max_tokens":512,"chat_template_kwargs":{"reasoning_effort":"low"},"messages":[{"role":"user","content":"What is 19 + 23? Reply only with the number."}]}' \
      2>/dev/null | grep -q '"content":"[^"]*42' && { note "ROLLED BACK by watchdog: LVKP serving"; return; }
    sleep 15
  done
  note "WATCHDOG RESTORE FAILED: :8100 down"
}
echo "$(date -Is) watchdog start for pid $PID, expires $(date -d @$END -Is)"
while [ "$(date +%s)" -lt "$END" ]; do
  alive=0; kill -0 $PID 2>/dev/null && alive=1
  age=$(( $(date +%s) - $(stat -c %Y $S 2>/dev/null || date +%s) ))
  for n in spark1 spark2 spark4; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 $n true 2>/dev/null; then miss[$n]=0; else miss[$n]=$(( ${miss[$n]} + 1 )); fi
    [ ${miss[$n]} -eq 3 ] && note "CRITICAL: $n unreachable for 3 checks (possible hard-hang); needs a power cycle"
  done
  echo "$(date -Is) pipeline=$([ $alive = 1 ] && echo $PID || echo dead) step_age=${age}s last='$(tail -1 $S)'"
  if [ $alive = 0 ]; then
    final || { grep -q 'stop LVKP' $S && restore "pipeline exited without a final line"; }
    echo "pipeline finished; watchdog done"; exit 0
  fi
  if [ $age -gt $STALL ]; then
    note "no progress for $((age/60)) min: killing pipeline $PID"
    pkill -TERM -P $PID; kill -TERM $PID; sleep 60; pkill -KILL -P $PID; kill -KILL $PID 2>/dev/null; sleep 5
    final || restore "stalled step"; exit 0
  fi
  sleep 60
done
note "watchdog expired after 3 h; pipeline still running (pid $PID)"
