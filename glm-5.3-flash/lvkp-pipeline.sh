#!/usr/bin/env bash
# lvkp-pipeline.sh — swap GLM-5.3 to fangkemi/knapcio's LVKP build (nvidia NVFP4 experts + 8-bit dense "lossless8",
# FP8 drafter, their kernel overlay) on our switchless ring, then measure. 2026-10-11.
# Detached:  setsid nohup ./lvkp-pipeline.sh > logs/lvkp/pipeline.log 2>&1 < /dev/null &    progress: logs/lvkp/STATUS
# Rolls back to the current serving build (glm-tp4.sh up) on any failure after GLM is taken down.
set -uo pipefail
G="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; L=$G/logs/lvkp; mkdir -p $L; S=$L/STATUS
R=/home/sparkmain/bench/4x-dgx-spark-ring/research/GLM-5.3-Flash-4x-DGX-Spark-TP4   # repo @ 3b29b25
O=/opt/glm53; M=$O/models
BASE_SRC=$HOME/models/nvidia/GLM-5.3-Flash-NVFP4; DRAFT_SRC=$HOME/glm53-dflash2-draft
IMG=glm53-roce:v11-b58f34ea
step() { echo "$(date -Is) $*" | tee -a $S; }
on() { local n=$1; shift; if [ "$n" = local ]; then bash -c "$*"; else ssh -o BatchMode=yes -o ConnectTimeout=15 "$n" "$*"; fi; }
GLM_DOWN=0; OK=0
rollback() {
  [ $GLM_DOWN = 1 ] && [ $OK = 0 ] || return 0
  step "ROLLBACK: stopping LVKP containers, restoring the previous GLM build"
  (cd $R && ENV_FILE=.env.switchless bash start.sh stop) >> $L/rollback.log 2>&1
  for n in local spark1 spark2 spark4; do on $n "for c in \$(docker ps -a --format '{{.Names}}' | grep '^glm53-switchless-r'); do docker stop \$c >/dev/null; done"; done
  sleep 15
  $G/glm-tp4.sh up >> $L/rollback.log 2>&1
  for i in $(seq 1 120); do
    curl -fsS -m 300 http://127.0.0.1:8100/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"glm-5.3-flash","temperature":0,"max_tokens":512,"chat_template_kwargs":{"reasoning_effort":"low"},"messages":[{"role":"user","content":"What is 19 + 23? Reply only with the number."}]}' \
      2>/dev/null | grep -q '"content":"[^"]*42' && { step "ROLLED BACK: previous GLM build serving on :8100"; return 0; }
    sleep 15
  done
  step "ROLLBACK FAILED: :8100 is down; see logs/lvkp/rollback.log and docs/CLUSTER-NOTES"
}
trap rollback EXIT

# 0. inputs
step "verify nvidia base @09b04e5e"
[ "$(sha256sum $BASE_SRC/config.json | cut -c1-64)" = e23c5d98f53e861d49a51bd3c68591621c5482ce829e42c31724152322fba03d ] || { step "base config hash mismatch"; exit 1; }
[ "$(ls $BASE_SRC/*.safetensors | wc -l)" = 33 ] || { step "base shard count != 33"; exit 1; }

# 1. GLM down (converter must not run alongside serving: knapcio docs/weights.md)
step "GLM down (current build stays on disk for rollback)"
GLM_DOWN=1; $G/glm-tp4.sh down > $L/glm-down.log 2>&1; sleep 10

# 2. image on every node (light: one C file, import tests) + /opt layout
step "build $IMG on all 4 nodes, create $O"
for n in local spark1 spark2 spark4; do
  on $n "sudo -n mkdir -p $O/models $O/overlay $O/src && sudo -n chown -R \$(id -u):\$(id -g) $O" || { step "mkdir $O failed on $n"; exit 1; }
done
for n in spark1 spark2 spark4; do rsync -a --delete --exclude .git -e "ssh -o BatchMode=yes" $R/ $n:$O/src/ || { step "repo sync to $n failed"; exit 1; }; done
rsync -a --delete --exclude .git $R/ $O/src/
for n in local spark1 spark2 spark4; do
  ( on $n "cd $O/src && docker build -f Dockerfile.roce -t $IMG ." > $L/build-$n.log 2>&1; echo "exit $?" >> $L/build-$n.log ) &
done; wait
for n in local spark1 spark2 spark4; do
  grep -q '^exit 0' $L/build-$n.log || { step "image build failed on $n: $(tail -3 $L/build-$n.log | tr '\n' ' ')"; exit 1; }
  step "image $n: $(on $n "docker image inspect -f '{{.Id}}' $IMG" | cut -c1-19)"
done

# 3. conversion on sparkmain, inside a capped CPU container (knapcio's exact command)
step "stage inputs under $M (hardlinks, same FS)"
mkdir -p $M/nvidia $M/incoai
[ -e $M/nvidia/GLM-5.3-Flash-NVFP4 ] || cp -al $BASE_SRC $M/nvidia/GLM-5.3-Flash-NVFP4
[ -e $M/incoai/GLM-5.3-Flash-DFlash2 ] || cp -al $DRAFT_SRC $M/incoai/GLM-5.3-Flash-DFlash2
step "convert: lossless8 target + FP8 drafter (CPU, 16 GB cap)"
docker run --name glm53-convert-lvkp-20261011 --network none --memory 16g --cpus 4 \
  --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$R:/recipe:ro" -v "$M:/models" --entrypoint bash $IMG -c '
    set -e
    bash /recipe/scripts/build_lossless8.sh /models/nvidia/GLM-5.3-Flash-NVFP4 /models/glm-quant-mix
    python3 /recipe/scripts/drafter_fp8.py /models/incoai/GLM-5.3-Flash-DFlash2 /models/incoai/GLM-5.3-Flash-DFlash2-fp8blk
  ' > $L/convert.log 2>&1 || { step "conversion failed: $(tail -3 $L/convert.log | tr '\n' ' ')"; exit 1; }
t=$(sha256sum $M/glm-quant-mix/lossless8/config.json | cut -c1-64); d=$(sha256sum $M/incoai/GLM-5.3-Flash-DFlash2-fp8blk/config.json | cut -c1-64)
step "config hashes: target $t (want f14dc13c…) drafter $d (want 15bc8429…)"
[ "$t" = f14dc13ce3bef88a5539c9e61b3e4f3dbef6958ebc3acda4b7f05f418642c3b0 ] && [ "$d" = 15bc842939ff7ca3ccc5aad36d25fff854da05a60086a4f55672d804fc6dbe7b ] \
  || { step "derived config hash mismatch vs knapcio's accepted build"; exit 1; }

# 4. distribute over the RoCE fabric: sparkmain->spark1 (164), sparkmain->spark4 (162), spark1->spark2 (160)
step "copy target + drafter to workers over the fabric"
cp_to() { rsync -aH --info=stats1 -e "ssh -o BatchMode=yes -o HostKeyAlias=$2 -o StrictHostKeyChecking=accept-new" \
            $M/glm-quant-mix $M/incoai "$3@$4:$M/" >> $L/copy-$2.log 2>&1; }
( cp_to x spark1 spark1 10.100.164.1; echo "exit $?" >> $L/copy-spark1.log
  ssh spark1 "rsync -aH -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' $M/glm-quant-mix $M/incoai spark2@10.100.160.1:$M/" > $L/copy-spark2.log 2>&1; echo "exit $?" >> $L/copy-spark2.log ) &
( cp_to x spark4 spark4 10.100.162.1; echo "exit $?" >> $L/copy-spark4.log ) &
wait
for n in spark1 spark2 spark4; do grep -q '^exit 0' $L/copy-$n.log || { step "copy to $n failed"; exit 1; }
  [ "$(on $n "sha256sum $M/glm-quant-mix/lossless8/config.json | cut -c1-64")" = "$t" ] || { step "copy verify failed on $n"; exit 1; }
  step "copied to $n: $(on $n "du -sh $M/glm-quant-mix/lossless8 | cut -f1")"; done

# 5. launch (their launcher, our ring env) and wait for a real chat
step "launch LVKP (ENV_FILE=.env.switchless)"
(cd $O/src && cp $R/.env.switchless . && ENV_FILE=.env.switchless bash start.sh serve) > $L/launch.log 2>&1 || { step "launcher refused: $(tail -3 $L/launch.log | tr '\n' ' ')"; exit 1; }
for i in $(seq 1 180); do   # 45 min (cold caches: overlay kernels JIT on first use)
  for r in 0 1 2 3; do n=$(echo local spark1 spark2 spark4 | cut -d' ' -f$((r+1)))
    st=$(on $n "docker inspect -f '{{.State.Status}}' glm53-switchless-r$r" 2>/dev/null)
    [ "$st" = running ] || { on $n "docker logs --tail 200 glm53-switchless-r$r" > $L/r$r-fail.log 2>&1; step "rank $r on $n is '${st:-missing}'"; exit 1; }
  done
  if curl -fsS -m 600 http://127.0.0.1:8100/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"glm-5.3-flash","temperature":0,"max_tokens":512,"chat_template_kwargs":{"reasoning_effort":"low"},"messages":[{"role":"user","content":"What is 19 + 23? Reply only with the number."}]}' \
      > $L/first-chat.json 2>/dev/null && grep -q '"content":"[^"]*42' $L/first-chat.json; then step "LVKP READY after $((i*15)) s"; break; fi
  [ $i = 180 ] && { step "LVKP not ready after 45 min"; exit 1; }
  sleep 15
done
for r in 0 1 2 3; do n=$(echo local spark1 spark2 spark4 | cut -d' ' -f$((r+1))); on $n "docker logs glm53-switchless-r$r" > $L/boot-r$r.log 2>&1; done
grep -h -E 'Connected all rings|NCCL WARN|KV cache size' $L/boot-r0.log | head -5 >> $S

# 6. gate + same measurements as the baseline
step "gate"; BASE_URL=http://127.0.0.1:8100/v1 bash $G/../research/glm-5.3-flash-4x-dgx-spark-switchless/scripts/gate.sh > $L/gate.log 2>&1
step "gate: $(grep -c PASS $L/gate.log) PASS / $(grep -c FAIL $L/gate.log) FAIL"
grep -q '  FAIL' $L/gate.log && { step "gate failed"; exit 1; }
for p in 1 2; do step "bench pass $p"; $G/bench.sh $G/raw/lvkp-pass$p > $G/raw/lvkp-pass$p.stdout 2>&1
  step "pass $p rows: $(tail -n +2 $G/raw/lvkp-pass$p/rows.tsv | cut -f1,3,4 | tr '\n\t' '; ')"; done
{ python3 $G/realtext_ttft_glm.py 28000 3 rt28-$(date +%s); python3 $G/realtext_ttft_glm.py 110000 3 rt110-$(date +%s); } > $G/raw/lvkp-realtext.log 2>&1
cat $G/raw/lvkp-realtext.log >> $S
docker run --rm --network host --entrypoint python3 -v /home/sparkmain/dsv41/miaai/scripts:/home/sparkmain/dsv41/miaai/scripts:ro \
  -v $G/qeval-glm.py:/q/qeval-glm.py:ro -v $G/qeval:/out -w /out ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6 \
  /q/qeval-glm.py run glm53-lvkp --url http://127.0.0.1:8100/v1/chat/completions > $G/qeval/qeval-glm53-lvkp.stdout 2>&1
step "qeval: $(grep -E '^[0-9]+/75 passed' $G/qeval/qeval-glm53-lvkp.stdout)"
OK=1; step "LVKP SERVING on :8100, measurements done"
