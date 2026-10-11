#!/usr/bin/env bash
# glm-tp4.sh up|down|status — GLM-5.3-Flash NVFP4 TP=4 + DFlash2 on the 4-Spark switchless ring, from sparkmain.
#
# Upstream recipe: alexellis/glm-5.3-flash-4x-dgx-spark-switchless @ e2d0839 (research/), scripts/rank-launcher.sh.
# The serve arguments and NCCL env below are that recipe verbatim; our deltas:
#   - bootstrap master = sparkmain LAN 192.168.1.70 on enP7s7 (all nodes); rank order follows the ring
#     sparkmain(0) -> spark1(1) -> spark2(2) -> spark4(3)
#   - NCCL_VARIANT=4hca (default): /opt/nccl-switchless-4hca, all 4 HCAs; the image's own pip libnccl is shadowed
#     with the same 2.30.7 build so one NCCL is loaded per process (same trick as dsv4-0731/eugr-boot-tp4.sh).
#     NCCL_VARIANT=v001: upstream's exact canonical v0.0.1 + 2 HCAs (rollback / A-B).
#   - port 8100 (the cluster's one serving port) instead of upstream's 8000
#   - image pinned by digest; weights = LibertAIDAI/GLM-5.3-Flash-NVFP4 @ 9e0d74e3 (upstream pin), staged by
#     stage/stage-node.sh as hard links into the HF cache (shards identical to the cached caca4e6a revision)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:?usage: glm-tp4.sh up|down|status}"
NODES=(local spark1 spark2 spark4)                 # rank 0..3
MASTER=192.168.1.70; MGMT_IF=enP7s7; MPORT=29520; PORT=8100
IMAGE=ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6
NAME=glm53_tp4
TEMPLATE_SHA=0c4099f3382d6c92700dfb99725025360966fd73032f0ecf32377c0d9e6309c5
TEMPLATE_DIR='$HOME/glm53-stage/template'   # expanded on each node (pinned upstream template)
NCCL_VARIANT="${NCCL_VARIANT:-4hca}"
case "$NCCL_VARIANT" in
  4hca) NCCL_DIR=/opt/nccl-switchless-4hca; NCCL_SHADOW=/opt/nccl-shadow-4hca
        NCCL_SHA=1c0dc70a00da7540be4c187921b19f4ffe7525e7b72a04fdc0b138c0d9ddfd1d
        HCA="rocep1s0f0,roceP2p1s0f0,rocep1s0f1,roceP2p1s0f1" ;;
  v001) NCCL_DIR=/opt/nccl-switchless-v0.0.1; NCCL_SHADOW=/opt/nccl-shadow
        NCCL_SHA=78cb83871792ec57d763d142e4cae26fc754ae284bcc81dcb2a7d50e17d4fa57
        HCA="rocep1s0f0,rocep1s0f1" ;;
  *) echo "unknown NCCL_VARIANT=$NCCL_VARIANT" >&2; exit 2 ;;
esac

on() { local n=$1; shift; if [ "$n" = local ]; then bash -c "$*"; else ssh -o BatchMode=yes -o ConnectTimeout=10 "$n" "$*"; fi; }

preflight() {
  on "$1" "
    set -e
    M=\$HOME/glm53-flash-nvfp4; D=\$HOME/glm53-dflash2-draft
    test -f \$M/config.json && test \$(ls \$M/*.safetensors | wc -l) = 120 && test -f \$D/model.safetensors
    echo '$NCCL_SHA  $NCCL_DIR/libnccl.so.2.30.7' | sha256sum -c --status
    echo '$NCCL_SHA  $NCCL_SHADOW/libnccl.so.2.30.7' | sha256sum -c --status
    echo \"$TEMPLATE_SHA  $TEMPLATE_DIR/chat_template.jinja\" | sha256sum -c --status
    docker image inspect $IMAGE >/dev/null
    for d in ${HCA//,/ }; do
      b=/sys/class/infiniband/\$d/ports/1
      [ \"\$(cat \$b/state)\" = '4: ACTIVE' ]
      [ \"\$(cat \$b/gid_attrs/types/3)\" = 'RoCE v2' ]
      [ \"\$(cat \$b/gids/3)\" != '0000:0000:0000:0000:0000:0000:0000:0000' ]
      [ \"\$(cat /sys/class/net/\$(cat \$b/gid_attrs/ndevs/3)/mtu)\" = 9000 ]
    done
    ! docker ps -a --format '{{.Names}}' | grep -qx $NAME
    [ -z \"\$(nvidia-smi --query-compute-apps=pid --format=csv,noheader)\" ]
    [ \$(df --output=avail -BG / | tail -1 | tr -dc 0-9) -ge 10 ]
  " || { echo "PRECONDITION FAILED on $1" >&2; exit 1; }
  echo "  preflight OK: $1"
}

launch() {
  local r=$1 n=${NODES[$1]} tail
  if [ "$r" = 0 ]; then tail="--host 0.0.0.0 --port $PORT"; else tail="--headless"; fi
  on "$n" "
    set -e
    MIP=\$(ip -4 route get $MASTER | grep -oE 'src [0-9.]+' | awk '{print \$2}')
    mkdir -p \$HOME/glm53-tp4-cache
    docker run -d --name $NAME --restart no \
      --cap-add IPC_LOCK --ulimit memlock=-1:-1 \
      --network host --ipc host --shm-size 32g --gpus all \
      --device /dev/infiniband:/dev/infiniband \
      -v \$HOME/glm53-flash-nvfp4:/model:ro \
      -v \$HOME/glm53-dflash2-draft:/draft:ro \
      -v $NCCL_DIR:/opt/patched-nccl:ro \
      -v $NCCL_SHADOW/libnccl.so.2.30.7:/usr/local/lib/python3.12/dist-packages/nvidia/nccl/lib/libnccl.so.2:ro \
      -v \$HOME/glm53-tp4-cache:/cache \
      -v $TEMPLATE_DIR/chat_template.jinja:/opt/glm53/chat_template.jinja:ro \
      -e LD_PRELOAD=/opt/patched-nccl/libnccl.so.2 -e VLLM_NCCL_SO_PATH=/opt/patched-nccl/libnccl.so.2 \
      -e NCCL_SKIP_TREE_CONNECT=1 -e NCCL_SWITCHLESS_RING_ONLY=1 \
      -e NCCL_SOCKET_IFNAME=$MGMT_IF -e GLOO_SOCKET_IFNAME=$MGMT_IF -e VLLM_HOST_IP=\$MIP \
      -e NCCL_NET=IB -e NCCL_IB_DISABLE=0 -e NCCL_IB_HCA==$HCA \
      -e NCCL_IB_GID_INDEX=3 -e NCCL_IB_SUBNET_PREFIX_LEN=24 -e NCCL_IB_SUBNET_AWARE_ROUTING=1 \
      -e NCCL_IB_MERGE_NICS=0 -e NCCL_NET_PLUGIN=none \
      -e NCCL_ALGO=Ring -e NCCL_PROTO=LL,LL128,Simple -e NCCL_P2P_LEVEL=SYS \
      -e NCCL_MIN_NCHANNELS=4 -e NCCL_MAX_NCHANNELS=4 -e NCCL_CROSS_NIC=1 -e NCCL_CUMEM_ENABLE=0 \
      -e NCCL_IGNORE_CPU_AFFINITY=1 -e NCCL_DEBUG=INFO -e NCCL_DEBUG_SUBSYS=INIT,NET \
      -e VLLM_ONE_GPU_PER_NODE=1 -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
      -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 -e PYTHONUNBUFFERED=1 \
      -e HF_HOME=/cache/hf -e XDG_CACHE_HOME=/cache -e VLLM_CACHE_ROOT=/cache/vllm \
      -e NODE_RANK=$r -e MASTER_ADDR=$MASTER \
      -e TORCH_CUDA_ARCH_LIST=12.1a -e FLASHINFER_CUDA_ARCH_LIST=12.1a \
      $IMAGE \
        /model \
        --served-model-name glm-5.3-flash --trust-remote-code \
        --tensor-parallel-size 4 --nnodes 4 --node-rank $r \
        --master-addr $MASTER --master-port $MPORT \
        --gpu-memory-utilization 0.85 --max-model-len 262144 \
        --max-num-seqs 6 --block-size 2304 --moe-backend marlin \
        --limit-mm-per-prompt '{\"image\":16}' \
        --kv-cache-dtype fp8_e4m3 --kv-cache-memory 12884901888 \
        --speculative-config '{\"method\":\"dflash\",\"model\":\"/draft\",\"num_speculative_tokens\":7}' \
        --tool-call-parser glm47 --enable-auto-tool-choice --reasoning-parser glm45 \
        --chat-template /opt/glm53/chat_template.jinja \
        --default-chat-template-kwargs '{\"reasoning_effort\":\"max\"}' \
        --distributed-executor-backend mp \
        $tail >/dev/null
    echo \"  launched rank $r on \$(hostname) mgmt=\$MIP\"
  "
}

case "$CMD" in
  up)
    echo "=== glm-tp4 up: nccl=$NCCL_VARIANT hca=$HCA port=$PORT ==="
    for n in "${NODES[@]}"; do preflight "$n"; done
    for r in 3 2 1 0; do launch $r; sleep 3; done      # workers first, head last (upstream order)
    echo "boot started; watch: docker logs -f $NAME (sparkmain). Gate before use: /v1/models AND a chat completion." ;;
  down)
    for n in "${NODES[@]}"; do on "$n" "docker rm -f $NAME >/dev/null 2>&1 && echo \"  removed $NAME on \$(hostname)\" || echo \"  no $NAME on \$(hostname)\""; done ;;
  status)
    for n in "${NODES[@]}"; do on "$n" "echo \"\$(hostname): \$(docker ps -a --filter name=^$NAME\$ --format '{{.Status}}')\""; done
    curl -s -m 5 http://127.0.0.1:$PORT/v1/models; echo ;;
  *) echo "usage: glm-tp4.sh up|down|status" >&2; exit 2 ;;
esac
