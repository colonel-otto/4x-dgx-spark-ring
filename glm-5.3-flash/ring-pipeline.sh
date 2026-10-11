#!/usr/bin/env bash
# ring-pipeline.sh — test knapcio PR #4 (RoCEnante over the sparkring mesh) on top of the serving LVKP build, 2026-10-11.
# Detached:  setsid nohup ./ring-pipeline.sh > logs/ring/pipeline.log 2>&1 < /dev/null &      progress: logs/ring/STATUS
# Keeps the ring build only if the gate passes, decode c1 beats LVKP and qeval holds; otherwise restarts the
# preserved LVKP containers (glm53-switchless-r3..r0) — a warm rollback.
set -uo pipefail
G="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; L=$G/logs/ring; mkdir -p $L; S=$L/STATUS
R=/home/sparkmain/bench/4x-dgx-spark-ring/research/GLM-5.3-Flash-4x-DGX-Spark-TP4      # branch sparkmain-ring (PR #4 merged)
SRC=/opt/glm53/src-ring; IMG=glm53-roce:v12-ring-sparkmain
NODES=(local spark1 spark2 spark4)
LVKP_C1=114.6   # LVKP c1 decode, mean of its two passes (111.6, 117.6)
step() { echo "$(date -Is) $*" | tee -a $S; }
on() { local n=$1; shift; if [ "$n" = local ]; then bash -c "$*"; else ssh -o BatchMode=yes -o ConnectTimeout=15 "$n" "$*"; fi; }
chat42() { curl -fsS -m 300 http://127.0.0.1:8100/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"glm-5.3-flash","temperature":0,"max_tokens":512,"chat_template_kwargs":{"reasoning_effort":"low"},"messages":[{"role":"user","content":"What is 19 + 23? Reply only with the number."}]}' \
  2>/dev/null | grep -q '"content":"[^"]*42'; }
LVKP_DOWN=0; KEEP=0
rollback() {
  [ $LVKP_DOWN = 1 ] && [ $KEEP = 0 ] || return 0
  step "ROLLBACK: stop ring containers, restart preserved LVKP (r3 -> r0)"
  (cd $SRC && ENV_FILE=.env.ring bash start.sh stop) >> $L/rollback.log 2>&1
  for r in 3 2 1 0; do on ${NODES[$r]} "docker stop glm53-ring-r$r >/dev/null 2>&1; true"; done; sleep 10
  for r in 3 2 1 0; do on ${NODES[$r]} "docker start glm53-switchless-r$r" >> $L/rollback.log 2>&1; sleep 3; done
  for i in $(seq 1 80); do chat42 && { step "ROLLED BACK: LVKP serving again on :8100"; return 0; }; sleep 15; done
  step "ROLLBACK FAILED: :8100 down; see docs/CLUSTER-NOTES (LVKP restart order) and logs/ring/rollback.log"
}
trap rollback EXIT
# The pipeline starts its own guard with its own PID. Launching both from an interactive shell with
# `setsid nohup … & P=$!` captured setsid's short-lived parent (job control makes it fork), so the first
# watchdog thought the pipeline was dead and restored LVKP mid-run (2026-10-11 19:00).
setsid nohup $G/ring-watchdog.sh $$ > $L/watchdog.log 2>&1 < /dev/null &

step "preflight: LAN stable (no enP7s7 link drop in 20 min), mesh markers + hw tc rules on all nodes"
for n in "${NODES[@]}"; do
  d=$(on $n "sudo -n journalctl --since '-20 min' --no-pager -k 2>/dev/null | grep -c 'enP7s7: link down'")
  [ "${d:-1}" = 0 ] || { step "LAN unstable on $n ($d link drops in 20 min): not starting"; exit 1; }
done
for n in "${NODES[@]}"; do
  m=$(on $n "systemctl list-units --no-legend 'dsv41-mesh-marker@*' | grep -c running"); [ "$m" = 2 ] || { step "mesh markers on $n: $m (want 2)"; exit 1; }
done

step "stop LVKP (containers preserved for rollback)"
LVKP_DOWN=1
(cd /opt/glm53/src && ENV_FILE=.env.switchless bash start.sh stop) > $L/lvkp-stop.log 2>&1
for r in 0 1 2 3; do on ${NODES[$r]} "docker stop glm53-switchless-r$r >/dev/null 2>&1; true"; done; sleep 10
for n in "${NODES[@]}"; do [ -z "$(on $n "nvidia-smi --query-compute-apps=pid --format=csv,noheader")" ] || { step "GPU busy on $n after stop"; exit 1; }; done

step "sync merged source to $SRC and build $IMG on all nodes"
for n in "${NODES[@]}"; do on $n "mkdir -p $SRC"; done
rsync -a --delete --exclude .git $R/ $SRC/
for n in spark1 spark2 spark4; do rsync -a --delete --exclude .git -e "ssh -o BatchMode=yes" $R/ $n:$SRC/ || { step "sync to $n failed"; exit 1; }; done
for n in "${NODES[@]}"; do ( on $n "cd $SRC && docker build -f Dockerfile.roce -t $IMG ." > $L/build-$n.log 2>&1; echo "exit $?" >> $L/build-$n.log ) & done; wait
for n in "${NODES[@]}"; do grep -q '^exit 0' $L/build-$n.log || { step "build failed on $n: $(tail -3 $L/build-$n.log | tr '\n' ' ')"; exit 1; }
  on $n "docker run --rm --entrypoint python3 $IMG -c 'import importlib.util as u; import sys; sys.path.insert(0,\"/opt/glm-roce-b12x\"); print(bool(u.find_spec(\"b12x.comm.roce_ring\")))'" 2>/dev/null | grep -q True \
    || { step "$IMG on $n lacks b12x.comm.roce_ring"; exit 1; }; done
step "images built, roce_ring present on all nodes"

step "ring smoke test (4 ranks, gloo, no vLLM/NCCL)"
# the smoke script sshes to every host incl. the head (ssh localhost is broken here: stale known_hosts entry), and
# defaults to 256 KiB messages; our mesh's hairpin queue (1024) caps them at 80 KiB.
(cd $SRC && FORCE=1 HOSTS="sparkmain@192.168.1.70 spark1 spark2 spark4" IPS="192.168.1.70 192.168.1.6 192.168.1.66 192.168.1.76" IMAGE=$IMG \
   GLM_ROCE_MAX_SIZE=81920 GLM_ROCE_GATHER_MAX_SIZE=81920 \
   B12X_ROCE_HCA=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1 \
   B12X_ROCE_PEER_HCA_MAPS="1=0/2,2=0/3,3=1/3;0=1/3,2=0/2,3=0/3;0=1/2,1=1/3,3=0/2;0=0/2,1=1/2,2=1/3" \
   GLOO_IFACE=enP7s7 timeout 900 bash roce/test_ring_smoke.sh $IMG) > $L/smoke.log 2>&1
grep -q 'RING-SMOKE PASS' $L/smoke.log || { step "ring smoke FAILED: $(tail -4 $L/smoke.log | tr '\n' ' ')"; exit 1; }
step "RING-SMOKE PASS"

step "launch ring build (ENV_FILE=.env.ring, KV 18 GiB)"
cp $R/.env.ring $SRC/
(cd $SRC && ENV_FILE=.env.ring bash start.sh serve) > $L/launch.log 2>&1 || { step "launcher refused: $(tail -3 $L/launch.log | tr '\n' ' ')"; exit 1; }
for i in $(seq 1 120); do   # 30 min
  for r in 0 1 2 3; do st=$(on ${NODES[$r]} "docker inspect -f '{{.State.Status}}' glm53-ring-r$r" 2>/dev/null)
    [ "$st" = running ] || { on ${NODES[$r]} "docker logs --tail 300 glm53-ring-r$r" > $L/r$r-fail.log 2>&1; step "rank $r is '${st:-missing}'"; exit 1; }; done
  chat42 && { step "RING READY after $((i*15)) s"; break; }
  [ $i = 120 ] && { step "ring build not ready after 30 min"; exit 1; }
  sleep 15
done
for r in 0 1 2 3; do on ${NODES[$r]} "docker logs glm53-ring-r$r" > $L/boot-r$r.log 2>&1; done
rr=$(grep -l 'GLM_ROCE_READY' $L/boot-r*.log | wc -l); step "GLM_ROCE_READY on $rr/4 ranks; devselect: $(grep -h -o -E 'DEVSELECT_BUILD_FAILED[^(]*|devselect: (built|ready)[^,]*' $L/boot-r0.log | head -1)"
[ "$rr" = 4 ] || { step "RoCEnante not ready on all ranks"; exit 1; }
grep -h 'KV cache size' $L/boot-r0.log | tail -1 >> $S

step "gate"; BASE_URL=http://127.0.0.1:8100/v1 bash $G/../research/glm-5.3-flash-4x-dgx-spark-switchless/scripts/gate.sh > $L/gate.log 2>&1
step "gate: $(grep -c '  PASS' $L/gate.log) PASS / $(grep -c '  FAIL' $L/gate.log) FAIL; $(grep 'warm decode:' $L/gate.log)"
grep -q '  FAIL' $L/gate.log && { step "gate failed"; exit 1; }
for p in 1 2; do $G/bench.sh $G/raw/ring-pass$p > $G/raw/ring-pass$p.stdout 2>&1
  step "pass $p rows: $(tail -n +2 $G/raw/ring-pass$p/rows.tsv | cut -f1,3,4 | tr '\n\t' '; ')"; done
{ python3 $G/realtext_ttft_glm.py 28000 3 rt28-$(date +%s); python3 $G/realtext_ttft_glm.py 110000 3 rt110-$(date +%s); } > $G/raw/ring-realtext.log 2>&1
cat $G/raw/ring-realtext.log >> $S
for q in 1 2; do docker run --rm --network host --entrypoint python3 -v /home/sparkmain/dsv41/miaai/scripts:/home/sparkmain/dsv41/miaai/scripts:ro \
  -v $G/qeval-glm.py:/q/qeval-glm.py:ro -v $G/qeval:/out -w /out ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6 \
  /q/qeval-glm.py run glm53-ring-$q --url http://127.0.0.1:8100/v1/chat/completions > $G/qeval/qeval-glm53-ring-$q.stdout 2>&1
  step "qeval $q: $(grep -E '^[0-9]+/75 passed' $G/qeval/qeval-glm53-ring-$q.stdout)"; done

c1=$(for p in 1 2; do awk -F'\t' 'NR==2{print $3}' $G/raw/ring-pass$p/rows.tsv; done | awk '{s+=$1} END{printf "%.1f", s/NR}')
q1=$(grep -oE '^[0-9]+' <(grep -E '^[0-9]+/75 passed' $G/qeval/qeval-glm53-ring-1.stdout)); q2=$(grep -oE '^[0-9]+' <(grep -E '^[0-9]+/75 passed' $G/qeval/qeval-glm53-ring-2.stdout))
step "decision inputs: c1 mean $c1 (LVKP $LVKP_C1), qeval $q1 / $q2 (LVKP 72)"
if awk -v a=$c1 -v b=$LVKP_C1 'BEGIN{exit !(a>b)}' && [ "${q1:-0}" -ge 70 ] && [ "${q2:-0}" -ge 70 ]; then
  KEEP=1; step "RING KEPT: serving on :8100 (glm53-ring-r0..3); LVKP containers stay preserved for rollback"
else
  step "ring not better (or quality dropped): rolling back"
fi
