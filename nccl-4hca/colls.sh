#!/usr/bin/env bash
# gate.sh <label> <v001|4hca> [ITERS]  — host-native np=4 all-reduce (ondigo tests/allreduce.cu), no containers.
# Ranks 0..3 = sparkmain, spark1, spark2, spark4 (ring order). Bootstrap over the LAN (enP7s7), data over RoCE.
set -uo pipefail
cd "$(dirname "$0")"; LABEL=$1; V=$2; ITERS=${3:-20}
NODES=(192.168.1.70 192.168.1.6 192.168.1.66 192.168.1.76); MASTER=192.168.1.70
case $V in
  v001) LIB='$HOME/nccl-switchless-v0.0.1'; HCA=rocep1s0f0,rocep1s0f1; NCH=4 ;;
  4hca) LIB='$HOME/nccl-switchless-4hca';   HCA=rocep1s0f0,roceP2p1s0f0,rocep1s0f1,roceP2p1s0f1; NCH=${NCH:-8} ;;
esac
ENV="LD_LIBRARY_PATH=$LIB ITERS=$ITERS NCCL_SWITCHLESS_RING_ONLY=1 NCCL_SKIP_TREE_CONNECT=1 NCCL_NET=IB NCCL_IB_DISABLE=0 \
 NCCL_IB_HCA==$HCA NCCL_IB_GID_INDEX=3 NCCL_IB_SUBNET_PREFIX_LEN=24 NCCL_IB_SUBNET_AWARE_ROUTING=1 NCCL_IB_MERGE_NICS=0 \
 NCCL_ALGO=Ring NCCL_PROTO=LL,LL128,Simple NCCL_P2P_LEVEL=SYS NCCL_MIN_NCHANNELS=$NCH NCCL_MAX_NCHANNELS=$NCH \
 NCCL_CROSS_NIC=1 NCCL_CUMEM_ENABLE=0 NCCL_IGNORE_CPU_AFFINITY=1 NCCL_NET_PLUGIN=none NCCL_SOCKET_IFNAME=enP7s7 \
 NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT,NET ${XENV:-}"
# per-PCIe-function RDMA tx (port_xmit_data is in 4-byte words); ethtool tx_bytes_phy is per physical port
DEVS4="rocep1s0f0 roceP2p1s0f0 rocep1s0f1 roceP2p1s0f1"
ctr() { for d in $DEVS4; do echo "$d $(( $(cat /sys/class/infiniband/$d/ports/1/counters/port_xmit_data) * 4 ))"; done; }
ctr > $LABEL.ctr0
for r in 3 2 1; do ssh -o BatchMode=yes ${NODES[$r]} "env $ENV timeout 180 \$HOME/nt/colls $r 4 $MASTER ${TEST:-all}" > $LABEL.r$r.log 2>&1 & done
sleep 1
env ${ENV//\$HOME/$HOME} timeout 180 $HOME/nt/colls 0 4 $MASTER ${TEST:-all} > $LABEL.r0.log 2>&1; rc=$?
wait; ctr > $LABEL.ctr1
echo "### $LABEL ($V, HCA=$HCA, nch=$NCH) rc=$rc"
grep -v "NCCL INFO" $LABEL.r0.log
grep -hE "WARN|ibv_|Error|error" $LABEL.r*.log | sort | uniq -c | head -8
echo "sparkmain tx bytes per PCIe-half during run:"; join $LABEL.ctr0 $LABEL.ctr1 | awk '{printf "  %-15s %8.2f GB\n",$1,($3-$2)/1e9}'
grep -h "SWITCHLESS/4HCA: listener\|Subnet-aware routing" $LABEL.r0.log | sort | uniq -c | head -12
