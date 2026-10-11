#!/usr/bin/env bash
# Queue of TP4-candidate GLM-5.3 checkpoints, sparkmain only, after the nvidia download finishes (2026-10-11).
# Pinned revisions; resumable (re-run on failure). Token from ~/.cache/huggingface/token (never in this file).
set -uo pipefail
L=$(dirname "$0")/logs/download-nvidia-nvfp4.log
until grep -q -E '^DONE' "$L"; do sleep 30; done
dl() { local repo=$1 rev=$2 dst=$3; echo "== $repo @ $rev -> $dst  start $(date -Is)"
  $HOME/hfenv/bin/hf download "$repo" --revision "$rev" --local-dir "$dst" --max-workers 8 >/dev/null 2>&1; local rc=$?
  echo "   exit $rc  $(date -Is)  files=$(ls "$dst" | wc -l) size=$(du -sh "$dst" | cut -f1)"; }
dl RedHatAI/GLM-5.3-Flash-NVFP4               18d55bfd5a2194887738da73753975c9d3842f46 $HOME/models/RedHatAI/GLM-5.3-Flash-NVFP4
dl Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold 76c0b5173166d2795dd48860f45d8224817f894c $HOME/models/Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold
echo "QUEUE DONE $(date -Is); free: $(df -h --output=avail / | tail -1)"
