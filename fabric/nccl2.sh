#!/bin/bash
# per-rank-HCA two-rank run. usage: nccl2.sh <tag> <op> <ipA> <ifA> <hcaA> <ipB> <ifB> <hcaB> [emax]
tag=$1; op=$2; ipA=$3; ifA=$4; hA=$5; ipB=$6; ifB=$7; hB=$8; emax=${9:-4G}
log=logs/nccl2.$tag.$op.log
LD=/usr/local/lib/python3.12/dist-packages/nvidia/nccl/lib:/usr/local/cuda/lib64:/usr/lib/aarch64-linux-gnu/openmpi/lib
C="-x LD_LIBRARY_PATH=$LD -x NCCL_IB_GID_INDEX=3 -x NCCL_IB_DISABLE=0 -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=INIT,NET"
APP="/ntb/${op}_perf -b 8 -e $emax -f 2 -g 1"
spec="-np 1 -host $ipA:1 -x NCCL_SOCKET_IFNAME=$ifA -x NCCL_IB_HCA==$hA $C $APP : -np 1 -host $ipB:1 -x NCCL_SOCKET_IFNAME=$ifB -x NCCL_IB_HCA==$hB $C $APP"
echo "# docker exec ntests_node mpirun --allow-run-as-root --mca btl_tcp_if_include enP7s7 --mca oob_tcp_if_include enP7s7 $spec" > $log
timeout ${TMO:-900} docker exec ntests_node mpirun --allow-run-as-root --mca btl_tcp_if_include enP7s7 --mca oob_tcp_if_include enP7s7 $spec >> $log 2>&1
echo "# exit=$?" >> $log
