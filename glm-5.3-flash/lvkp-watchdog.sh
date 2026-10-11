#!/usr/bin/env bash
# lvkp-watchdog.sh — guard for lvkp-pipeline.sh (2026-10-11). Expires after 5 h. Every 60 s logs a heartbeat; acts
# only to get a GLM back on :8100 (the previous build via glm-tp4.sh), never touches the fabric or model files:
#   - pipeline gone without "LVKP SERVING" / "ROLLED BACK" after GLM was taken down -> restore previous GLM
#   - no new STATUS line for 120 min (hung conversion/copy/boot)                     -> kill pipeline, restore
#   - a node fails ssh 3 checks in a row                                            -> log CRITICAL (needs a human)
set -uo pipefail
G="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; L=$G/logs/lvkp; S=$L/STATUS
R=/home/sparkmain/bench/4x-dgx-spark-ring/research/GLM-5.3-Flash-4x-DGX-Spark-TP4
END=$(( $(date +%s) + 5*3600 )); STALL=$(( 120*60 ))
PID=${1:?usage: lvkp-watchdog.sh <pipeline pid>}
declare -A miss=([spark1]=0 [spark2]=0 [spark4]=0)
note() { echo "$(date -Is) [watchdog] $*" | tee -a $S; }
done_ok() { grep -qE 'LVKP SERVING|ROLLED BACK' $S; }
restore() {
  note "restore previous GLM build (reason: $1)"
  (cd $R && ENV_FILE=.env.switchless bash start.sh stop) >> $L/watchdog-restore.log 2>&1
  for n in spark1 spark2 spark4; do ssh -o BatchMode=yes $n "for c in \$(docker ps --format '{{.Names}}' | grep '^glm53-switchless-r'); do docker stop \$c >/dev/null; done"; done
  for c in $(docker ps --format '{{.Names}}' | grep '^glm53-switchless-r'); do docker stop $c >/dev/null; done
  docker rm -f glm53-convert-lvkp-20261011 >/dev/null 2>&1; sleep 15
  $G/glm-tp4.sh up >> $L/watchdog-restore.log 2>&1
  for i in $(seq 1 120); do
    curl -fsS -m 300 http://127.0.0.1:8100/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"glm-5.3-flash","temperature":0,"max_tokens":512,"chat_template_kwargs":{"reasoning_effort":"low"},"messages":[{"role":"user","content":"What is 19 + 23? Reply only with the number."}]}' \
      2>/dev/null | grep -q '"content":"[^"]*42' && { note "ROLLED BACK by watchdog: previous GLM build serving"; return; }
    sleep 15
  done
  note "WATCHDOG RESTORE FAILED: :8100 down; recovery in docs/CLUSTER-NOTES"
}
echo "$(date -Is) watchdog start for pid $PID, expires $(date -d @$END -Is)"
while [ "$(date +%s)" -lt "$END" ]; do
  alive=0; kill -0 $PID 2>/dev/null && alive=1
  age=$(( $(date +%s) - $(stat -c %Y $S 2>/dev/null || date +%s) ))
  for n in spark1 spark2 spark4; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 $n true 2>/dev/null; then miss[$n]=0; else miss[$n]=$(( ${miss[$n]} + 1 )); fi
    [ ${miss[$n]} -eq 3 ] && note "CRITICAL: $n unreachable for 3 checks (possible OOM hard-hang); needs a power cycle"
  done
  echo "$(date -Is) pipeline=$([ $alive = 1 ] && echo $PID || echo dead) step_age=${age}s last='$(tail -1 $S)'"
  if [ $alive = 0 ]; then
    done_ok || { grep -q 'GLM down' $S && restore "pipeline exited without finishing"; }
    echo "pipeline finished; watchdog done"; exit 0
  fi
  if [ $age -gt $STALL ]; then
    note "no progress for $((age/60)) min: killing pipeline $PID"
    pkill -TERM -P $PID; kill -TERM $PID; sleep 60; pkill -KILL -P $PID; kill -KILL $PID 2>/dev/null; sleep 5
    done_ok || restore "stalled step"; exit 0
  fi
  sleep 60
done
note "watchdog expired after 5 h; pipeline still running (pid $PID)"
