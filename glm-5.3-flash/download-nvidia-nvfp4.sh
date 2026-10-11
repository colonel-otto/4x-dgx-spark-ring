#!/usr/bin/env bash
# Pinned download for the fangkemi lossless8 build (docs/weights.md): nvidia/GLM-5.3-Flash-NVFP4 @ 09b04e5e
# (config sha256 e23c5d98…, shards identical to HEAD da920bb0). sparkmain only; resumable (re-run on failure).
set -uo pipefail
DST=$HOME/models/nvidia/GLM-5.3-Flash-NVFP4; REV=09b04e5e74bca08ca8549fc736d4cdd8624bfde3
echo "start $(date -Is)"
HF_HUB_ENABLE_HF_TRANSFER=0 $HOME/hfenv/bin/hf download nvidia/GLM-5.3-Flash-NVFP4 --revision $REV --local-dir "$DST" --max-workers 8
echo "hf exit $? $(date -Is)"
echo "config sha256: $(sha256sum $DST/config.json | cut -c1-64) (want e23c5d98f53e861d49a51bd3c68591621c5482ce829e42c31724152322fba03d)"
echo "files: $(ls $DST | wc -l) shards: $(ls $DST/*.safetensors | wc -l) size: $(du -sh $DST | cut -f1)"
echo DONE
