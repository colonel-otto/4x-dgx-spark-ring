#!/usr/bin/env bash
# run-all.sh — unattended GLM-5.3-Flash TP=4 measurement on the ring, then put DSv4.1 back (2026-10-11).
# Run detached:  nohup ./run-all.sh > logs/run-all.log 2>&1 &     progress: logs/STATUS
# Steps: wait for the spark1 Qwen offload -> pull the pinned image on spark1 -> stop DSv4.1 -> boot GLM
# (NCCL 4hca, fallback v001) -> gate (upstream gate.sh) -> bench x2 + real-text prefill -> qeval (sandboxed
# container) -> leave GLM serving (user decision 2026-10-11). Any failure after DSv4.1 is stopped restores DSv4.1.
set -uo pipefail
G="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; L=$G/logs; mkdir -p $L
IMG=ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6
GATE=$G/../research/glm-5.3-flash-4x-dgx-spark-switchless/scripts/gate.sh
MIAAI=/home/sparkmain/dsv41/miaai
step() { echo "$(date -Is) $*" | tee -a $L/STATUS; }
DSV_STOPPED=0
GLM_OK=0

restore_dsv41() {
  [ $DSV_STOPPED = 1 ] && [ $GLM_OK = 0 ] || return 0
  step "restore: GLM down, DSv4.1 serve"
  $G/glm-tp4.sh down >> $L/glm-down.log 2>&1
  (cd $MIAAI && ./start-tp4.sh serve) > $L/dsv41-restore.log 2>&1 \
    || (cd $MIAAI && ./start-tp4.sh stop && sleep 20 && ./start-tp4.sh serve) >> $L/dsv41-restore.log 2>&1
  if curl -fsS -m 180 http://127.0.0.1:8100/v1/chat/completions -H 'Content-Type: application/json' \
       -d '{"model":"deepseek-v4.1-flash","temperature":0,"max_tokens":16,"chat_template_kwargs":{"thinking":false},"messages":[{"role":"user","content":"What is 19 + 23? Reply only with the number."}]}' \
       > $L/dsv41-restore-chat.json 2>&1 && grep -q 42 $L/dsv41-restore-chat.json; then
    step "DSv4.1 RESTORED: /v1/chat/completions answered 42"; DSV_STOPPED=0
  else
    step "DSv4.1 RESTORE FAILED — see logs/dsv41-restore.log (needs a human)"
  fi
}
trap restore_dsv41 EXIT

wait_glm() {   # $1 = label; ready = /v1/models lists glm-5.3-flash AND a real chat completion returns content
  local i
  for i in $(seq 1 240); do   # 40 min
    for n in local spark1 spark2 spark4; do
      st=$( [ $n = local ] && docker inspect -f '{{.State.Status}}' glm53_tp4 2>/dev/null || ssh $n "docker inspect -f '{{.State.Status}}' glm53_tp4" 2>/dev/null )
      [ "$st" = running ] || { step "$1: glm53_tp4 on $n is '${st:-missing}'"; return 1; }
    done
    if curl -fsS -m 5 http://127.0.0.1:8100/v1/models 2>/dev/null | grep -q glm-5.3-flash; then
      curl -fsS -m 600 http://127.0.0.1:8100/v1/chat/completions -H 'Content-Type: application/json' \
        -d '{"model":"glm-5.3-flash","temperature":0,"max_tokens":512,"chat_template_kwargs":{"reasoning_effort":"low"},"messages":[{"role":"user","content":"What is 19 + 23? Reply only with the number."}]}' \
        > $L/$1-first-chat.json 2>&1 && grep -q '"content":"[^"]*42' $L/$1-first-chat.json && { step "$1: READY after $((i*10)) s (chat answered 42)"; return 0; }
      step "$1: /v1/models up but chat not right yet: $(head -c 300 $L/$1-first-chat.json)"
    fi
    sleep 10
  done
  step "$1: timed out after 40 min"; return 1
}

collect_boot_logs() {
  docker logs glm53_tp4 > $L/$1-rank0.log 2>&1
  for n in spark1 spark2 spark4; do ssh $n 'docker logs glm53_tp4' > $L/$1-$n.log 2>&1; done
}

# 1. spark1 disk: wait for the verified offload, then pull the image
step "waiting for spark1 Qwen offload"
until grep -qE '^DONE|FAILED' $L/offload-qwen.log 2>/dev/null; do sleep 30; done
grep -q '^DONE' $L/offload-qwen.log || { step "offload failed: $(tail -2 $L/offload-qwen.log) — stopping before any engine change"; exit 1; }
step "offload done, spark1 free: $(ssh spark1 'df -h --output=avail / | tail -1')"
ssh spark1 "docker pull $IMG" > $L/pull-spark1.log 2>&1 || { step "spark1 pull failed"; exit 1; }
for n in local spark1 spark2 spark4; do
  id=$( [ $n = local ] && docker image inspect -f '{{.Id}}' $IMG || ssh $n "docker image inspect -f '{{.Id}}' $IMG" )
  step "image $n: $id"
  [ "$id" = sha256:35c6f70ffcba62fd67d7b9d4b4e8300ad177201792ce9cdb1ea18fd449bc23b6 ] || { step "image mismatch on $n"; exit 1; }
done

# 2. stop DSv4.1
step "stopping DSv4.1"
DSV_STOPPED=1
(cd $MIAAI && ./start-tp4.sh stop) > $L/dsv41-stop.log 2>&1   # stop.sh:70 fixed 2026-10-11 (workers were never stopped)
sleep 20

# 3. boot GLM: 4hca first, upstream v001 as fallback
VARIANT=""
for v in 4hca v001; do
  step "GLM boot nccl=$v"
  NCCL_VARIANT=$v $G/glm-tp4.sh up > $L/boot-$v.log 2>&1 || { step "launcher failed ($v): $(tail -3 $L/boot-$v.log | tr '\n' ' ')"; $G/glm-tp4.sh down >/dev/null 2>&1; sleep 15; continue; }
  if wait_glm boot-$v; then VARIANT=$v; break; fi
  collect_boot_logs boot-$v; $G/glm-tp4.sh down >/dev/null 2>&1; sleep 20
done
[ -n "$VARIANT" ] || { step "GLM did not come up on either NCCL variant"; exit 1; }
collect_boot_logs boot-$VARIANT
grep -E 'KV cache|GPU KV cache size|Maximum concurrency' $L/boot-$VARIANT-rank0.log | tail -3 >> $L/STATUS

# 4. gate
step "gate (upstream gate.sh)"
BASE_URL=http://127.0.0.1:8100/v1 bash $GATE > $L/gate.log 2>&1; step "gate exit $?: $(grep -cE 'PASS' $L/gate.log) PASS / $(grep -cE 'FAIL' $L/gate.log) FAIL"

# 5. benchmarks: two passes + real-text prefill
for p in 1 2; do
  step "bench pass $p"; $G/bench.sh $G/raw/$VARIANT-pass$p > $G/raw/$VARIANT-pass$p.stdout 2>&1
  step "pass $p rows: $(tail -n +2 $G/raw/$VARIANT-pass$p/rows.tsv | cut -f1,3,4 | tr '\n\t' '; ')"
done
step "real-text prefill"
{ python3 $G/realtext_ttft_glm.py 28000 3 rt28-$(date +%s); python3 $G/realtext_ttft_glm.py 110000 3 rt110-$(date +%s); } > $G/raw/$VARIANT-realtext.log 2>&1
cat $G/raw/$VARIANT-realtext.log >> $L/STATUS

# 6. quality: MiaAI qeval in a throwaway container (model-written code runs there, not on the host)
step "qeval"
mkdir -p $G/qeval
docker run --rm --network host --entrypoint python3 \
  -v $MIAAI/scripts:$MIAAI/scripts:ro -v $G/qeval-glm.py:/q/qeval-glm.py:ro -v $G/qeval:/out -w /out \
  $IMG /q/qeval-glm.py run glm53-$VARIANT --url http://127.0.0.1:8100/v1/chat/completions > $G/qeval/qeval-glm53-$VARIANT.stdout 2>&1
step "qeval: $(tail -3 $G/qeval/qeval-glm53-$VARIANT.stdout | tr '\n' ' ')"

step "ALL MEASUREMENTS DONE (variant $VARIANT)"
# 7. leave GLM serving if the gate passed; otherwise the EXIT trap restores DSv4.1
if ! grep -q '  FAIL' $L/gate.log && curl -fsS -m 600 http://127.0.0.1:8100/v1/chat/completions -H 'Content-Type: application/json' \
     -d '{"model":"glm-5.3-flash","temperature":0,"max_tokens":512,"chat_template_kwargs":{"reasoning_effort":"low"},"messages":[{"role":"user","content":"What is 19 + 23? Reply only with the number."}]}' \
     2>/dev/null | grep -q '"content":"[^"]*42'; then
  GLM_OK=1; step "GLM-5.3 SERVING on :8100 (nccl=$VARIANT), left up as the serving engine"
else
  step "gate had FAILs or final chat failed; falling back to DSv4.1"
fi
