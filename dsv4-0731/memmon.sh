#!/bin/bash
# every 15 s: per-node used/avail GB, swap used, GPU power -> memmon.tsv
out=${1:-memmon.tsv}
while true; do
  for n in 192.168.1.70 192.168.1.6 192.168.1.66 192.168.1.76; do
    l=$(ssh -o BatchMode=yes -o ConnectTimeout=5 $n 'free -m | awk "/Mem:/{u=\$3;a=\$7} /Swap:/{s=\$3} END{printf \"%d\t%d\t%d\", u,a,s}"; printf "\t%s" "$(nvidia-smi --query-gpu=power.draw,temperature.gpu --format=csv,noheader,nounits | tr -d " ")"' 2>/dev/null || echo UNREACHABLE)
    printf '%s\t%s\t%s\n' "$(date +%T)" "$n" "$l"
  done >> "$out"
  sleep 15
done
