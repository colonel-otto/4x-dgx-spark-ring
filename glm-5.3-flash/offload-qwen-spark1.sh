#!/usr/bin/env bash
# Move spark1's local-inference-lab/Qwen3.8-Flash-Next-NVFP4 HF cache to spark4:~/offload/spark1-hf-hub (user-approved
# 2026-10-11 to make room for the GLM image). Relayed through sparkmain (spark1 has no host key for spark4).
# Deletes the spark1 copy ONLY if file count, symlink count and total bytes match on both sides.
set -uo pipefail
Q=models--local-inference-lab--Qwen3.8-Flash-Next-NVFP4
cnt='cd $HOME/BASE/'$Q' && echo "$(find . -type f | wc -l) $(find . -type l | wc -l) $(find . -type f -printf "%s\n" | awk "{s+=\$1} END{print s}")"'
echo "start $(date -Is)"
ssh spark4 "rm -rf \$HOME/offload/spark1-hf-hub/$Q && mkdir -p \$HOME/offload/spark1-hf-hub" || exit 1
ssh spark1 "tar -C \$HOME/.cache/huggingface/hub -cf - $Q" | ssh spark4 "tar -C \$HOME/offload/spark1-hf-hub -xf -"
st=("${PIPESTATUS[@]}"); echo "tar pipe exit ${st[*]} $(date -Is)"
[ "${st[0]}" = 0 ] && [ "${st[1]}" = 0 ] || { echo "COPY FAILED"; exit 1; }
a=$(ssh spark1 "${cnt/BASE/.cache/huggingface/hub}"); b=$(ssh spark4 "${cnt/BASE/offload/spark1-hf-hub}")
echo "spark1: $a"; echo "spark4: $b"
[ -n "$a" ] && [ "$a" = "$b" ] || { echo "VERIFY FAILED, spark1 copy kept"; exit 1; }
ssh spark1 "rm -rf \$HOME/.cache/huggingface/hub/$Q && df -h --output=avail / | tail -1"
echo "DONE $(date -Is)"
