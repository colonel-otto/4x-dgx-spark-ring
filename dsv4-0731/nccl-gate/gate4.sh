#!/bin/bash
# 4-rank nccl-tests with the switchless NCCL (LD_PRELOAD), run inside ntest4_node.
# usage: gate4.sh <op> <tag> <hca0> <hca1> <hca2> <hca3> [emax]
cd "$(dirname "$0")"
op=$1; tag=$2; H=($3 $4 $5 $6); emax=${7:-4G}
HOSTS=(192.168.1.70 192.168.1.6 192.168.1.66 192.168.1.76)
log=logs/np4.$tag.$op.log
LD=/opt/patched-nccl:/usr/local/cuda/lib64:/usr/lib/aarch64-linux-gnu/openmpi/lib
C="-x LD_LIBRARY_PATH=$LD -x LD_PRELOAD=/opt/patched-nccl/libnccl.so.2 -x NCCL_SKIP_TREE_CONNECT=1 -x NCCL_SWITCHLESS_RING_ONLY=1 \
 -x NCCL_SOCKET_IFNAME=enP7s7 -x NCCL_NET=IB -x NCCL_IB_DISABLE=0 -x NCCL_IB_GID_INDEX=3 -x NCCL_IB_SUBNET_PREFIX_LEN=24 \
 -x NCCL_IB_SUBNET_AWARE_ROUTING=1 -x NCCL_IB_MERGE_NICS=0 -x NCCL_ALGO=Ring -x NCCL_PROTO=LL,LL128,Simple -x NCCL_P2P_LEVEL=SYS \
 -x NCCL_MIN_NCHANNELS=4 -x NCCL_MAX_NCHANNELS=4 -x NCCL_CROSS_NIC=1 -x NCCL_CUMEM_ENABLE=0 -x NCCL_IGNORE_CPU_AFFINITY=1 \
 -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=INIT,NET $EXTRA_X"
APP="/ntb/${op}_perf -b 8 -e $emax -f 2 -g 1 -c 1"
spec=""
for r in 0 1 2 3; do [ $r -gt 0 ] && spec+=" : "; spec+="-np 1 -host ${HOSTS[$r]}:1 -x NCCL_IB_HCA==${H[$r]} $C $APP"; done
echo "# docker exec ntest4_node mpirun --allow-run-as-root --mca btl_tcp_if_include enP7s7 --mca oob_tcp_if_include enP7s7 $spec" > $log
timeout ${TMO:-900} docker exec ntest4_node mpirun --allow-run-as-root --mca btl_tcp_if_include enP7s7 --mca oob_tcp_if_include enP7s7 $spec >> $log 2>&1
echo "# exit=$?" >> $log
