#!/usr/bin/env bash
# Build ~/glm53-flash-nvfp4 = LibertAIDAI/GLM-5.3-Flash-NVFP4 @ 9e0d74e3 (recipe pin) from the local HF cache
# (rev caca4e6a: identical shards) by hard links, plus the 4 small 9e0d files from $1. Same for the DFlash2 drafter.
set -euo pipefail
SRC=$1; HUB=$HOME/.cache/huggingface/hub
SNAP=$HUB/models--LibertAIDAI--GLM-5.3-Flash-NVFP4/snapshots/caca4e6a4ebbd66f159d3d2fc256683fd6e27177
DSNAP=$(ls -d $HUB/models--incoai--GLM-5.3-Flash-DFlash2/snapshots/* | head -1)
M=$HOME/glm53-flash-nvfp4; DR=$HOME/glm53-dflash2-draft
[ -e $M ] && { echo "$M exists, refusing"; exit 1; }
mkdir -p $M $DR
while read -r oid p; do
  [ -e "$SRC/rev-9e0d74e3/$p" ] && continue
  blob=$(readlink -f "$SNAP/$p"); [ "$(basename $blob)" = "$oid" ] || { echo "oid mismatch $p"; exit 1; }
  ln "$blob" "$M/$p"
done < $SRC/lfs-9e0d74e3.txt
for f in $SNAP/*; do b=$(basename $f); [ -e "$M/$b" ] || [ "$b" = model-input-scales.safetensors ] || [ -e "$SRC/rev-9e0d74e3/$b" ] || ln "$(readlink -f $f)" "$M/$b"; done
cp $SRC/rev-9e0d74e3/* $M/
for f in $DSNAP/*; do ln "$(readlink -f $f)" "$DR/$(basename $f)"; done
echo "$(hostname): model files=$(ls $M | wc -l) st=$(ls $M/*.safetensors | wc -l) draft=$(ls $DR | tr '\n' ' ')"
