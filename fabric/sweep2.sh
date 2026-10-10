source ./lib.sh
# run_set <tag> <port0> <extra> <link indices...>
run_set() {
  local tag=$1 p0=$2 extra=$3; shift 3
  local i=0 pids=()
  for idx in "$@"; do
    IFS='|' read name cn cd sip sn sd <<<"${LINKS[$idx]}"
    on $sn "timeout 60 ib_write_bw -d $sd -x 3 -p $((p0+i)) -F -D 10 --report_gbits $extra >/dev/null 2>&1 &"
    i=$((i+1))
  done
  sleep 2; i=0
  for idx in "$@"; do
    IFS='|' read name cn cd sip sn sd <<<"${LINKS[$idx]}"
    ( on $cn "timeout 50 ib_write_bw -d $cd -x 3 -p $((p0+i)) -F -D 10 --report_gbits $extra $sip" > logs/$tag.$name.log 2>&1 ) &
    i=$((i+1))
  done
  wait
  for idx in "$@"; do IFS='|' read name rest <<<"${LINKS[$idx]}"
    echo -e "$tag\t$name\t$(awk 'NF==5 && $1~/^[0-9]+$/{print $4}' logs/$tag.$name.log | tail -1)" >> dual.tsv; done
}
: > dual.tsv
run_set edge1 20100 "" 0 1
run_set edge2 20110 "" 2 3
run_set edge3 20120 "" 4 5
run_set edge4 20130 "" 6 7
run_set ring8 20140 "" 0 1 2 3 4 5 6 7
run_set ring8bidir 20160 "-b" 0 1 2 3 4 5 6 7
run_set edge1bidir 20180 "-b" 0 1
