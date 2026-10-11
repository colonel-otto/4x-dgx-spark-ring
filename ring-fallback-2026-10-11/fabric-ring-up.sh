#!/usr/bin/env bash
# Re-apply the switchless 4-node RoCE ring. RUN AFTER EVERY REBOOT and after any
# docker up/down churn -- addressing, MTU and the DOCKER-USER chain are runtime-only.
# Site-specific version of alexellis/glm-5.3-flash-4x-dgx-spark-switchless
# scripts/fabric-setup.sh, adapted for the DUAL-rail ring (both CX-7 cards).
#
# Ring:  sparkmain --(164/165)-- spark1 --(160/161)-- spark2 --(166/167)-- spark4 --(162/163)-- sparkmain
# Every cable joins an f0 port to an f1 port. Card 1 = enp1s0f*, card 2 = enP2p1s0f*.
set -u
IFS_ALL="enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1"

# node | f0-card1 | f0-card2 | f1-card1 | f1-card2
NODES=(
  "sparkmain 10.100.164.2 10.100.165.2 10.100.162.2 10.100.163.2"
  "spark1    10.100.160.2 10.100.161.2 10.100.164.1 10.100.165.1"
  "spark2    10.100.166.1 10.100.167.1 10.100.160.1 10.100.161.1"
  "spark4    10.100.162.1 10.100.163.1 10.100.166.2 10.100.167.2"
)

run_on() { h=$1; shift; if [ "$h" = sparkmain ]; then bash -c "$*"; else
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12 "$h" "$*"; fi; }

echo "=== applying ring ==="
for row in "${NODES[@]}"; do
  set -- $row; h=$1; a_f0c1=$2; a_f0c2=$3; a_f1c1=$4; a_f1c2=$5
  run_on "$h" "
    set -e
    for d in $IFS_ALL; do sudo -n nmcli device set \$d managed no 2>/dev/null || true; done
    sleep 2
    # A down/up cycle is what compacts the NIC GID table so the RoCE v2 GID lands
    # at index 3. Without it NCCL_IB_GID_INDEX=3 reads an all-zero GID. See notes.
    for d in $IFS_ALL; do
      sudo -n ip addr flush dev \$d 2>/dev/null || true
      sudo -n ip link set \$d down 2>/dev/null || true
    done
    sleep 2
    for d in $IFS_ALL; do sudo -n ip link set \$d mtu 9000 up; done
    sleep 4
    sudo -n ip addr add $a_f0c1/24 dev enp1s0f0np0
    sudo -n ip addr add $a_f0c2/24 dev enP2p1s0f0np0
    sudo -n ip addr add $a_f1c1/24 dev enp1s0f1np1
    sudo -n ip addr add $a_f1c2/24 dev enP2p1s0f1np1
    sudo -n sysctl -qw net.ipv4.ip_forward=1 || true
    for IF in $IFS_ALL; do
      sudo -n iptables -C DOCKER-USER -i \$IF -j ACCEPT 2>/dev/null || sudo -n iptables -I DOCKER-USER -i \$IF -j ACCEPT
      sudo -n iptables -C DOCKER-USER -o \$IF -j ACCEPT 2>/dev/null || sudo -n iptables -I DOCKER-USER -o \$IF -j ACCEPT
    done
    echo \"  \$(hostname): f0=$a_f0c1,$a_f0c2  f1=$a_f1c1,$a_f1c2  mtu=9000\"
  " || echo "  !! $h FAILED"
done

echo "=== GID index 3 must be RoCE v2 and non-zero on all 16 HCAs ==="
for row in "${NODES[@]}"; do set -- $row; h=$1
  run_on "$h" 'for hca in rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1; do
      t=$(cat /sys/class/infiniband/$hca/ports/1/gid_attrs/types/3 2>/dev/null)
      g=$(cat /sys/class/infiniband/$hca/ports/1/gids/3 2>/dev/null)
      st=ok; [ "$t" = "RoCE v2" ] || st=BAD; case "$g" in 0000:0000:0000:0000:0000:0000:0000:0000|"") st=BAD-ZERO;; esac
      [ "$st" = ok ] || printf "  !! %s %s %s %s\n" "$(hostname)" "$hca" "${t:-none}" "$st"
    done; echo "  $(hostname): gid idx3 checked"'
done

echo "=== jumbo path, all 8 links (necessary, NOT sufficient -- only a real collective proves the ring) ==="
jp() { if [ "$1" = sparkmain ]; then r=$(ping -M do -s 8972 -c3 -q -W2 "$3" 2>&1|grep "packet loss");
       else r=$(run_on "$1" "ping -M do -s 8972 -c3 -q -W2 $3 2>&1|grep 'packet loss'"); fi
       printf "  %-30s %s\n" "$2" "$(echo $r|sed 's/, time.*//')"; }
jp sparkmain "E1 r1 sparkmain->spark1"  10.100.164.1
jp sparkmain "E1 r2 sparkmain->spark1"  10.100.165.1
jp spark1    "E2 r1 spark1->spark2"     10.100.160.1
jp spark1    "E2 r2 spark1->spark2"     10.100.161.1
jp spark2    "E3 r1 spark2->spark4"     10.100.166.2
jp spark2    "E3 r2 spark2->spark4"     10.100.167.2
jp spark4    "E4 r1 spark4->sparkmain"  10.100.162.2
jp spark4    "E4 r2 spark4->sparkmain"  10.100.163.2
echo "=== done. Bandwidth re-check: ~109 Gb/s per link, ~196 Gb/s per edge with both rails. ==="
