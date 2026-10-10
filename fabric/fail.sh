cd ~/bench/fabric-2026-10-09
clean() { for h in sparkmain spark1 spark2 spark4; do if [ $h = sparkmain ]; then docker exec ntests_node pkill -9 -f "mpirun|_perf" ; else ssh $h 'docker exec ntests_node pkill -9 -f "mpirun|_perf"'; fi; done >/dev/null 2>&1; }
TMO=200 ./nccl_run.sh all_reduce 3 1 fabric 1M; clean
TMO=200 ./nccl_run.sh all_reduce 4 1 fabric 1M; clean
for np in 3 4; do for r in 1 2; do for op in all_reduce all_gather reduce_scatter alltoall; do
  TMO=200 ./nccl_run.sh $op $np $r lan 1M; clean
done; done; done
echo done > fail.done
