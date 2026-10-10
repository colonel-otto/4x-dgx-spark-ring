# links: name|clientnode|clientdev|serverip|servernode|serverdev|clientip
LINKS=(
"E1r1|sparkmain|rocep1s0f0|10.100.164.1|spark1|rocep1s0f1"
"E1r2|sparkmain|roceP2p1s0f0|10.100.165.1|spark1|roceP2p1s0f1"
"E2r1|spark1|rocep1s0f0|10.100.160.1|spark2|rocep1s0f1"
"E2r2|spark1|roceP2p1s0f0|10.100.161.1|spark2|roceP2p1s0f1"
"E3r1|spark2|rocep1s0f0|10.100.166.2|spark4|rocep1s0f1"
"E3r2|spark2|roceP2p1s0f0|10.100.167.2|spark4|roceP2p1s0f1"
"E4r1|spark4|rocep1s0f0|10.100.162.2|sparkmain|rocep1s0f1"
"E4r2|spark4|roceP2p1s0f0|10.100.163.2|sparkmain|roceP2p1s0f1"
)
on() { local n=$1; shift; if [ "$n" = sparkmain ]; then bash -c "$*"; else ssh -o BatchMode=yes $n "$*"; fi; }
# pt <link> <port> <tool> <extra args...> ; prints client output
pt() {
  local L=$1 port=$2 tool=$3; shift 3
  IFS='|' read name cn cd sip sn sd <<<"$L"
  on $sn "timeout 90 $tool -d $sd -x 3 -p $port -F $* >/dev/null 2>&1 &" 
  sleep 1
  on $cn "timeout 80 $tool -d $cd -x 3 -p $port -F $* $sip"
}
