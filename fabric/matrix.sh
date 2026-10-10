cd ~/bench/fabric-2026-10-09
R1A=rocep1s0f0; R1B=rocep1s0f1; R2A=rocep1s0f0,roceP2p1s0f0; R2B=rocep1s0f1,roceP2p1s0f1
IA=enp1s0f0np0; IB=enp1s0f1np1
for op in all_reduce all_gather reduce_scatter alltoall; do
  ./nccl2.sh sm-s1.rail1 $op 192.168.1.70 $IA $R1A 192.168.1.6 $IB $R1B
  ./nccl2.sh sm-s1.both  $op 192.168.1.70 $IA $R2A 192.168.1.6 $IB $R2B
done
for e in "s1-s2 192.168.1.6 192.168.1.66" "s2-s4 192.168.1.66 192.168.1.76" "s4-sm 192.168.1.76 192.168.1.70"; do set -- $e
  ./nccl2.sh $1.rail1 all_reduce $2 $IA $R1A $3 $IB $R1B
  ./nccl2.sh $1.both  all_reduce $2 $IA $R2A $3 $IB $R2B
done
echo MATRIX_DONE > matrix.done
