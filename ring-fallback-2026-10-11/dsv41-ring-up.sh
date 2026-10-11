#!/usr/bin/env bash
# dsv41-ring-up.sh — re-apply the runtime-only state DeepSeek-V4.1 TP=4 (and DSv4 TP=4 on spark2) need,
# after ~/fabric-ring-up.sh, on every reboot. Idempotent. Run from sparkmain with the engine STOPPED
# (mesh-up must never run under a live RoCEnante engine).
#   1. NFS exports from sparkmain (exportfs, runtime):  DSv4.1 -> spark1/spark4/spark2, DSv4-0731 -> spark2
#   2. spark2 <-> sparkmain /32 routes through spark1 (spark2 is the opposite node: no direct cable)
#   3. spark2: DSv4-0731 NFS mount at /tmp/dsv4tp4/hf-DeepSeek-V4-Flash-0731 (its local copy was removed 2026-10-10)
#   4. RoCEnante opposite-node mesh (sparkring cx7_hairpin_diagonal) on all 4 nodes: marker unit in /run, mesh-up
# Undo the mesh: ssh <node> sudo /opt/dsv41-mesh/mesh-down.sh  (it also deletes the step-2 routes; re-run this script)
set -euo pipefail
M41=/home/sparkmain/models/DeepSeek-V4.1-Flash
M40=/home/sparkmain/dsv4/hf-DeepSeek-V4-Flash-0731
UNIT=/home/sparkmain/dsv41/miaai/scripts/ring_mesh/dsv41-mesh-marker@.service
MESH=/home/sparkmain/dsv41/ring-mesh

echo "== 1. NFS exports"
for c in 10.100.164.1 10.100.162.1 10.100.160.1; do sudo -n exportfs -o ro,sync,no_subtree_check,no_root_squash,insecure "$c:$M41"; done
sudo -n exportfs -o ro,sync,no_subtree_check,no_root_squash,insecure "10.100.160.1:$M40"

echo "== 2. spark2 <-> sparkmain routes via spark1"
sudo -n ip route replace 10.100.160.1/32 via 10.100.164.1 dev enp1s0f0np0 src 10.100.164.2
ssh spark2 'sudo -n ip route replace 10.100.164.2/32 via 10.100.160.2 dev enp1s0f1np1 src 10.100.160.1'
ssh spark2 'ping -c2 -W2 -M do -s 8972 -I 10.100.160.1 10.100.164.2 >/dev/null' && echo "  jumbo ping spark2 -> sparkmain OK"

echo "== 3. spark2 DSv4-0731 NFS mount"
ssh spark2 "sudo -n mkdir -p /tmp/dsv4tp4/hf-DeepSeek-V4-Flash-0731; mountpoint -q /tmp/dsv4tp4/hf-DeepSeek-V4-Flash-0731 || sudo -n mount -t nfs4 -o ro,nfsvers=4.2,nconnect=8,rsize=1048576,hard,timeo=600,clientaddr=10.100.160.1 10.100.164.2:$M40 /tmp/dsv4tp4/hf-DeepSeek-V4-Flash-0731; ls /tmp/dsv4tp4/hf-DeepSeek-V4-Flash-0731/*.safetensors | wc -l"

echo "== 4. RoCEnante mesh"
for p in "sparkmain 192.168.1.70" "spark1 spark1" "spark2 spark2" "spark4 spark4"; do
  set -- $p
  scp -q "$UNIT" "$2:/tmp/dsv41-mesh-marker@.service"
  scp -q "$MESH/mesh-up-$1.sh" "$MESH/mesh-down-$1.sh" "$2:/tmp/"
  ssh "$2" "sudo -n install -m 644 /tmp/dsv41-mesh-marker@.service /run/systemd/system/ \
    && sudo -n install -m 755 /tmp/mesh-up-$1.sh /opt/dsv41-mesh/mesh-up.sh \
    && sudo -n install -m 755 /tmp/mesh-down-$1.sh /opt/dsv41-mesh/mesh-down.sh \
    && sudo -n systemctl daemon-reload && sudo -n /opt/dsv41-mesh/mesh-up.sh" | sed "s/^/  $1: /"
done
echo "dsv41-ring-up: done. Boot with: cd ~/dsv41/miaai && ./start-tp4.sh serve"
