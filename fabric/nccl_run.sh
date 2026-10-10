#!/bin/bash
# usage: nccl_run.sh <op> <np> <rails:1|2> <sock:fabric|lan> [extra maxbytes]
op=$1; np=$2; rails=$3; sock=$4; emax=${5:-4G}
HOSTS=(192.168.1.70 192.168.1.6 192.168.1.66 192.168.1.76)
NAMES=(sparkmain spark1 spark2 spark4)
# fabric netdev toward rank r+1 (bootstrap) for np=2 only
if [ $rails = 1 ]; then HCA="=rocep1s0f0,rocep1s0f1"; else HCA="=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1"; fi
if [ $sock = lan ]; then IFS_=(enP7s7 enP7s7 enP7s7 enP7s7); else IFS_=(enp1s0f0np0 enp1s0f1np1 x x); fi
log=logs/nccl.${op}.np${np}.rail${rails}.${sock}.log
COMMON="-x LD_LIBRARY_PATH=/usr/local/lib/python3.12/dist-packages/nvidia/nccl/lib:/usr/local/cuda/lib64:/usr/lib/aarch64-linux-gnu/openmpi/lib -x NCCL_IB_GID_INDEX=3 -x NCCL_IB_DISABLE=0 $EXTRA_X -x NCCL_IB_HCA=$HCA -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=INIT,NET"
APP="/ntb/${op}_perf -b 8 -e $emax -f 2 -g 1"
spec=""
for ((r=0;r<np;r++)); do
  [ $r -gt 0 ] && spec+=" : "
  spec+="-np 1 -host ${HOSTS[$r]}:1 -x NCCL_SOCKET_IFNAME=${IFS_[$r]} $COMMON $APP"
done
echo "# $spec" > $log
timeout ${TMO:-600} docker exec ntests_node mpirun --allow-run-as-root --mca btl_tcp_if_include enP7s7 --mca oob_tcp_if_include enP7s7 $spec >> $log 2>&1
echo "# exit=$?" >> $log
