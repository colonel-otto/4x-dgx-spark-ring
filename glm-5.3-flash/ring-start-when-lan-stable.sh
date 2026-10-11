#!/usr/bin/env bash
# Starts ring-pipeline.sh once no node has had a LAN (enP7s7) carrier drop for 20 min; gives up after 2 h.
G="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; END=$(( $(date +%s) + 7200 ))
on() { local n=$1; shift; if [ "$n" = local ]; then bash -c "$*"; else ssh -o BatchMode=yes -o ConnectTimeout=10 "$n" "$*"; fi; }
while [ "$(date +%s)" -lt "$END" ]; do
  bad=0; for n in local spark1 spark2 spark4; do
    d=$(on $n "sudo -n journalctl --since '-20 min' --no-pager -k 2>/dev/null | grep -c 'enP7s7: link down'" 2>/dev/null); [ "${d:-1}" = 0 ] || bad=1; done
  if [ $bad = 0 ]; then mkdir -p $G/logs/ring; echo "$(date -Is) LAN stable 20 min: starting ring-pipeline"
    exec setsid nohup $G/ring-pipeline.sh > $G/logs/ring/pipeline.log 2>&1 < /dev/null; fi
  sleep 60
done
echo "$(date -Is) LAN never stable for 20 min within 2 h: ring test NOT started"
