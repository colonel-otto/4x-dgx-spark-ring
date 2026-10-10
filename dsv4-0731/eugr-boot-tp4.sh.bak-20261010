#!/usr/bin/env bash
# eugr-boot-tp4.sh — DeepSeek-V4-Flash-0731 TP=4 on the 4-Spark switchless ring, eugr engine (Track A).
# Adapted from ~/eugr-boot.sh (3-node TP=3); the original is untouched.
#
# Deltas vs eugr-boot.sh:
#   - 4 nodes in ring order == rank order: sparkmain, spark1, spark2, spark4 (LAN IPs; master = 192.168.1.70)
#   - recipe ./recipes/dsv4-tp4-nst5-mnbt8192.yaml (tensor_parallel 4, both served names)
#   - weights at /tmp/dsv4tp4/hf-DeepSeek-V4-Flash-0731 on every node (real dir: hardlink farm on
#     sparkmain/spark2/spark4, read-only bind of the NFS mount on spark1) -> /models/dsv4host
#   - switchless NCCL 2.30.7 (/opt/nccl-switchless-v0.0.1, sha256 78cb8387...) via LD_PRELOAD + VLLM_NCCL_SO_PATH,
#     NCCL_SWITCHLESS_RING_ONLY=1, NCCL_SKIP_TREE_CONNECT=1, NCCL_ALGO=Ring (env of upstream rank-launcher.sh)
#   - NCCL_IB_HCA = card-1 pair (rocep1s0f0,rocep1s0f1) on every rank: the hardened patch refuses >2 HCAs
#     ("more than two eligible listener GIDs"), and f0->next / f1->prev is uniform on all nodes, so the
#     list is identical per rank. Proven by the np=4 nccl-tests gate (nccl-gate/).
#   - container name dsv4_tp4 (never collides with vllm_node / sglang_node)
#   - no NCCL_TIMEOUT=3600 (watch the boot instead)
#
# Usage: eugr-boot-tp4.sh [logfile]      (IMAGE=... to override the image)
set -euo pipefail

NST=5; MNBT=8192
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${1:-$HERE/logs/eugr-tp4-nst${NST}-mnbt${MNBT}-$(date +%Y%m%dT%H%M%S).log}"
IMAGE="${IMAGE:-eugr/spark-vllm-b12x:local-20260823}"   # digest 7dc02f16 = the TP=2/TP=3 baseline image
NODES="192.168.1.70,192.168.1.6,192.168.1.66,192.168.1.76"
NAME=dsv4_tp4
CACHE_ROOT=/opt/eugrcache
RECIPE="$HERE/recipes/dsv4-tp4-nst${NST}-mnbt${MNBT}.yaml"
LAUNCHER="$HOME/eugr-launcher"
HCA="rocep1s0f0,rocep1s0f1"

echo "=== eugr-boot-tp4: image=$IMAGE recipe=$RECIPE log=$LOG ==="

# ---- preconditions on every node ---------------------------------------------
for n in ${NODES//,/ }; do
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$n" "
    set -e
    test -f /tmp/dsv4tp4/hf-DeepSeek-V4-Flash-0731/config.json
    test -f /opt/nccl-switchless-v0.0.1/libnccl.so.2
    echo '78cb83871792ec57d763d142e4cae26fc754ae284bcc81dcb2a7d50e17d4fa57  /opt/nccl-switchless-v0.0.1/libnccl.so.2.30.7' | sha256sum -c --status
    docker image inspect $IMAGE >/dev/null
    for d in vllm flashinfer triton tilelang; do test -d ${CACHE_ROOT}-\$d; done
    for d in ${HCA//,/ }; do
      b=/sys/class/infiniband/\$d/ports/1
      [ \"\$(cat \$b/gid_attrs/types/3)\" = 'RoCE v2' ]
      [ \"\$(cat \$b/gids/3)\" != '0000:0000:0000:0000:0000:0000:0000:0000' ]
      [ \"\$(cat /sys/class/net/\$(cat \$b/gid_attrs/ndevs/3)/mtu)\" = 9000 ]
    done
    ! docker ps -a --format '{{.Names}}' | grep -qx $NAME
    [ -z \"\$(nvidia-smi --query-compute-apps=pid --format=csv,noheader)\" ]
  " || { echo "PRECONDITION FAILED on $n"; exit 1; }
  echo "  preconditions OK: $n"
done

ARGS=(
  -t "$IMAGE" -n "$NODES" --name "$NAME" --eth-if enP7s7 --ib-if "$HCA"
  -v /tmp/dsv4tp4:/models/dsv4host
  -v ${CACHE_ROOT}-vllm:/root/.cache/vllm
  -v ${CACHE_ROOT}-flashinfer:/root/.cache/flashinfer
  -v ${CACHE_ROOT}-triton:/root/.triton
  -v ${CACHE_ROOT}-tilelang:/root/.tilelang
  -v /opt/nccl-switchless-v0.0.1:/opt/patched-nccl:ro
  # one NCCL per process: instanttensor dlopens the image's system libnccl (2.31.2) next to the preloaded
  # 2.30.7 -> 'corrupted comm object' + instanttensor._C.open std::exception (boot 1). Shadow both copies.
  # rw binds of a COPY (/opt/nccl-shadow, same sha256): docker 29.6 (spark4) refuses docker cp into a container with ro file binds.
  -v /opt/nccl-shadow/libnccl.so.2.30.7:/usr/lib/aarch64-linux-gnu/libnccl.so.2.31.2
  -v /opt/nccl-shadow/libnccl.so.2.30.7:/usr/local/lib/python3.12/dist-packages/nvidia/nccl/lib/libnccl.so.2
  --no-cache-dirs --gpu-memory-utilization 0.82 --port 8100
  -e "NCCL_IB_HCA==$HCA"
  -e NCCL_NET=IB -e NCCL_IB_DISABLE=0 -e NCCL_IB_GID_INDEX=3
  -e NCCL_IB_SUBNET_PREFIX_LEN=24 -e NCCL_IB_SUBNET_AWARE_ROUTING=1 -e NCCL_IB_MERGE_NICS=0
  -e NCCL_NET_PLUGIN=none -e NCCL_BUFFSIZE=16777216
  -e LD_PRELOAD=/opt/patched-nccl/libnccl.so.2 -e VLLM_NCCL_SO_PATH=/opt/patched-nccl/libnccl.so.2
  -e NCCL_SKIP_TREE_CONNECT=1 -e NCCL_SWITCHLESS_RING_ONLY=1
  -e NCCL_ALGO=Ring -e NCCL_PROTO=LL,LL128,Simple -e NCCL_P2P_LEVEL=SYS
  -e NCCL_MIN_NCHANNELS=4 -e NCCL_MAX_NCHANNELS=4 -e NCCL_CROSS_NIC=1 -e NCCL_CUMEM_ENABLE=0
  -e NCCL_DEBUG=INFO -e NCCL_DEBUG_SUBSYS=INIT,NET
  -e MAX_JOBS=2
)

cd "$LAUNCHER"
DRY=$(HF_HOME=/tmp/hfcache python3 run-recipe.py "$RECIPE" "${ARGS[@]}" --dry-run 2>&1)
echo "$DRY" > "${LOG%.log}.dryrun.txt"
echo "$DRY" | grep -q -- "--port 8100"                          || { echo "DRYRUN FAIL: port"; echo "$DRY" | tail -40; exit 1; }
echo "$DRY" | grep -q -- "--tensor-parallel-size 4"             || { echo "DRYRUN FAIL: tp"; exit 1; }
echo "$DRY" | grep -q "deepseek-v4-flash-eugr-ab"               || { echo "DRYRUN FAIL: ab name"; exit 1; }
echo "$DRY" | grep -q "\"num_speculative_tokens\":${NST}"       || { echo "DRYRUN FAIL: nst"; exit 1; }
echo "$DRY" | grep -q -- "--max-num-batched-tokens ${MNBT}"     || { echo "DRYRUN FAIL: mnbt"; exit 1; }
[ "$(echo "$DRY" | grep -c -- '--speculative-config')" -eq 1 ] || { echo "DRYRUN FAIL: duplicate --speculative-config"; exit 1; }
echo "  dry-run checks PASSED"

date +%s > "${LOG%.log}.t0"
HF_HOME=/tmp/hfcache nohup python3 run-recipe.py "$RECIPE" "${ARGS[@]}" > "$LOG" 2>&1 &
echo "  launched pid $! -> $LOG"
