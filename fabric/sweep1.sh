source ./lib.sh
P=19000
: > lat.tsv; : > bw.tsv; : > ping.tsv
for L in "${LINKS[@]}"; do
  IFS='|' read name cn cd sip sn sd <<<"$L"
  for tool in ib_write_lat ib_send_lat; do for s in 2 64 4096 65536; do
    P=$((P+1))
    out=$(pt "$L" $P $tool -s $s -n 10000 2>&1); echo "$out" > logs/$name.$tool.$s.log
    echo -e "$name\t$tool\t$s\t$(echo "$out" | awk '$1=='$s' && NF>=8{print $5"\t"$6"\t"$8}' | tail -1)" >> lat.tsv
  done; done
  P=$((P+1)); out=$(pt "$L" $P ib_write_bw -D 5 --report_gbits 2>&1); echo "$out" > logs/$name.ib_write_bw.log
  echo -e "$name\t$(echo "$out" | awk 'NF==5 && $1~/^[0-9]+$/{print $4}' | tail -1)" >> bw.tsv
  # ping: from client node to server ip
  p1=$(on $cn "ping -c 50 -i 0.01 -q $sip" | tee logs/$name.ping64.log | grep rtt)
  p2=$(on $cn "ping -c 50 -i 0.01 -q -M do -s 8972 $sip" | tee logs/$name.ping8972.log | grep rtt)
  echo -e "$name\t$p1\t$p2" >> ping.tsv
done
