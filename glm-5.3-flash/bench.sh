#!/usr/bin/env bash
# bench.sh <out-dir> [cells] — GLM-5.3-Flash NVFP4 TP=4 (vLLM + DFlash2, alexellis recipe) on :8100.
# Same cells as ../dsv41-flash/bench.sh (exactly 128 output tokens, unique cold prefix, warm-up discarded);
# only change: reasoning_effort=low (GLM-5.3 cannot disable thinking). Recipe caps --max-num-seqs 6, so c8/c16 queue.
# cells: "conc depth" (default both). Warm-up pass discarded (MiaAI: first runs after boot hit a cold Engram cache).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?out dir}"; CELLS="${2:-conc depth}"; mkdir -p "$OUT"
BASE=http://127.0.0.1:8100/v1; MODEL=glm-5.3-flash; H="$HERE/bench-glm.py"
med() { sort -n | awk '{v[NR]=$1} END{print (NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2}'; }
echo "start $(date -Is)" > "$OUT/timeline.txt"
for c in 1 4 8 16; do python3 "$H" --base-url $BASE --model $MODEL --prompt 256 --concurrency $c --repeat 1 --output-tokens 128 --nonce-base "warm-$(date +%s%N)" > "$OUT/warmup-c$c.log" 2>&1; done
NB="run-$(date +%s)"
if [[ " $CELLS " == *" conc "* ]]; then
  printf 'c\toutput_tokens\tmedian_decode_tok_s\tagg_tok_s\tttft_ms\n' > "$OUT/rows.tsv"
  for c in 1 4 8 16; do
    python3 "$H" --base-url $BASE --model $MODEL --prompt 256 --concurrency $c --repeat 5 --output-tokens 128 --nonce-base "$NB" > "$OUT/bench-c$c.log" 2>&1
    dec=$(grep '^FINAL' "$OUT/bench-c$c.log" | sed -E 's/.*= ([0-9.]+) tok.*/\1/')
    agg=$(grep '^trial' "$OUT/bench-c$c.log" | sed -E 's/.*agg=([0-9.]+).*/\1/' | med)
    ttft=$(grep '^trial' "$OUT/bench-c$c.log" | sed -E 's/.*ttft=([0-9]+)ms.*/\1/' | med)
    printf '%s\t128\t%s\t%s\t%s\n' $c "$dec" "$agg" "$ttft" >> "$OUT/rows.tsv"
  done
  echo "concurrency done $(date -Is)" >> "$OUT/timeline.txt"
fi
if [[ " $CELLS " == *" depth "* ]]; then
  printf 'prompt\treps\tmedian_decode_tok_s\tmin\tmax\tmedian_ttft_ms\n' > "$OUT/depth.tsv"
  for p in 2048 8192 32768 131072; do
    reps=5; [ $p -ge 32768 ] && reps=3
    python3 "$H" --base-url $BASE --model $MODEL --prompt $p --concurrency 1 --repeat $reps --output-tokens 128 --nonce-base "$NB" > "$OUT/depth-$p.log" 2>&1
    dec=$(grep '^FINAL' "$OUT/depth-$p.log" | sed -E 's/.*= ([0-9.]+) tok\/s \(min ([0-9.]+) max ([0-9.]+)\).*/\1\t\2\t\3/')
    ttft=$(grep '^trial' "$OUT/depth-$p.log" | sed -E 's/.*ttft=([0-9]+)ms.*/\1/' | med)
    printf '%s\t%s\t%s\t%s\n' $p $reps "$dec" "$ttft" >> "$OUT/depth.tsv"
  done
  echo "depth done $(date -Is)" >> "$OUT/timeline.txt"
fi
echo "done $(date -Is)" >> "$OUT/timeline.txt"
