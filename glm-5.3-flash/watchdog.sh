#!/usr/bin/env bash
# watchdog.sh — detached guard for run-all.sh (GLM-5.3 TP=4 measurement, 2026-10-11). Expires after 2 h.
# Run:  setsid nohup ./watchdog.sh > logs/watchdog.log 2>&1 < /dev/null &
# Every 60 s: heartbeat (run-all alive, last STATUS step, node ssh, spark1 disk, engine containers).
# It acts only to get DSv4.1 back; it never touches the fabric, images or model files:
#   - run-all.sh gone after it stopped DSv4.1, and no RESTORED line  -> restore DSv4.1 itself
#   - no new STATUS line for 75 min (hung step)                       -> kill run-all.sh, restore
#   - spark1 root disk < 2 GB while running                           -> kill run-all.sh, restore
#   - a node fails ssh 3 checks in a row                               -> log CRITICAL (a hard-hang needs a human)
# On expiry it logs the state and exits; run-all.sh keeps its own EXIT trap that restores DSv4.1.
set -uo pipefail
G="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; L=$G/logs; S=$L/STATUS
MIAAI=/home/sparkmain/dsv41/miaai
END=$(( $(date +%s) + 2*3600 ))
STALL=$(( 75*60 ))
declare -A miss=([spark1]=0 [spark2]=0 [spark4]=0)
log() { echo "$(date -Is) $*"; }
note() { echo "$(date -Is) [watchdog] $*" | tee -a $S; }
runall_pid() { pgrep -f 'glm-5.3-flash/run-all.sh' | head -1; }

restore() {
  note "restore: GLM down, DSv4.1 serve (reason: $1)"
  $G/glm-tp4.sh down >> $L/watchdog-restore.log 2>&1
  (cd $MIAAI && ./start-tp4.sh serve) >> $L/watchdog-restore.log 2>&1 \
    || (cd $MIAAI && ./start-tp4.sh stop && sleep 20 && ./start-tp4.sh serve) >> $L/watchdog-restore.log 2>&1
  if curl -fsS -m 180 http://127.0.0.1:8100/v1/chat/completions -H 'Content-Type: application/json' \
       -d '{"model":"deepseek-v4.1-flash","temperature":0,"max_tokens":16,"chat_template_kwargs":{"thinking":false},"messages":[{"role":"user","content":"What is 19 + 23? Reply only with the number."}]}' \
       2>/dev/null | grep -q 42; then
    note "DSv4.1 RESTORED by watchdog: chat answered 42"
  else
    note "DSv4.1 RESTORE FAILED (watchdog) — see logs/watchdog-restore.log; recovery steps in docs/CLUSTER-NOTES (2026-10-11)"
  fi
}

needs_restore() { grep -q 'stopping DSv4.1' $S && ! grep -qE 'RESTORED|GLM-5.3 SERVING' $S; }

kill_runall() {   # $1 reason; SIGTERM, then make sure, then restore ourselves (no double restore: run-all is gone)
  local p; p=$(runall_pid); [ -n "$p" ] || return 0
  note "killing run-all.sh pid $p: $1"
  pkill -TERM -P "$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null; sleep 30
  pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; sleep 5
}

log "watchdog start, expires $(date -d @$END -Is)"
while [ "$(date +%s)" -lt "$END" ]; do
  p=$(runall_pid); last=$(tail -1 $S 2>/dev/null)
  age=$(( $(date +%s) - $(stat -c %Y $S) ))
  d1=$(ssh -o BatchMode=yes -o ConnectTimeout=5 spark1 "df --output=avail -BM / | tail -1 | tr -dc 0-9" 2>/dev/null || echo "?")
  ctn=$(docker ps --format '{{.Names}}' | grep -E '^(dsv41-head|glm53_tp4)$' | tr '\n' ' ')
  for n in spark1 spark2 spark4; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 $n true 2>/dev/null; then miss[$n]=0; else miss[$n]=$(( ${miss[$n]} + 1 )); fi
    [ ${miss[$n]} -eq 3 ] && note "CRITICAL: $n unreachable over ssh for 3 checks (possible OOM hard-hang) — needs a human/power cycle"
  done
  log "run-all=${p:-dead} step_age=${age}s spark1_free=${d1}MB head_ctn=[${ctn}] last='${last}'"

  if [ -z "$p" ]; then
    if needs_restore; then restore "run-all.sh exited without restoring DSv4.1"; fi
    log "run-all.sh finished; watchdog done"; exit 0
  fi
  if [ "$age" -gt "$STALL" ]; then
    kill_runall "no STATUS progress for $((age/60)) min"; needs_restore && restore "stalled step"; exit 0
  fi
  if [ "$d1" != "?" ] && [ "$d1" -lt 2048 ] && grep -q 'stopping DSv4.1' $S; then
    kill_runall "spark1 root disk down to ${d1} MB"; needs_restore && restore "spark1 disk"; exit 0
  fi
  sleep 60
done
note "watchdog expired after 2 h; run-all.sh still running (pid $(runall_pid)), its own EXIT trap restores DSv4.1"
