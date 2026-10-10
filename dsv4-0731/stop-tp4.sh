#!/usr/bin/env bash
# Remove ONLY the dsv4_tp4 container, by exact name, on each of the 4 nodes (lists first).
for n in 192.168.1.70 192.168.1.6 192.168.1.66 192.168.1.76; do
  echo "== $n: $(ssh -o BatchMode=yes $n "docker ps -a --format '{{.Names}}' | tr '\n' ' '")"
  ssh -o BatchMode=yes $n 'docker ps -a --format "{{.Names}}" | grep -qx dsv4_tp4 && docker rm -f dsv4_tp4 || true'
done
