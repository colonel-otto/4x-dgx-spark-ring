#!/usr/bin/env bash
# bench-tp4.sh — Track A benchmark of the live TP=4 eugr engine, matched to the TP=2/TP=3 eugr baselines:
#   harness = vendored scripts/eugr-ab/bench-miaai.py (sha256 675b0f24...; temp 0.6, top_p 0.95, thinking=false,
#   256-token unique cold prefix, min=max=128 completion tokens, ignore_eos), median-of-5, warm-up sweep discarded.
# Extra cells: depth sweep 2K/8K/32K/131K (c=1), prompt-effect pair (eugr-remaining-cells-v2.py --cells prompt).
# /metrics snapshots around every phase for DSpark acceptance; memmon runs separately.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/raw/bench-$(date +%Y%m%dT%H%M%S)}"; mkdir -p "$OUT"
ENGINE_LOG="${ENGINE_LOG:?set ENGINE_LOG}"
BASE=http://127.0.0.1:8100/v1; MODEL=deepseek-v4-flash-eugr-ab; H="$HERE/harness/bench-miaai.py"
snap() { curl -s http://127.0.0.1:8100/metrics | grep -E '^vllm:(spec_decode_num_(drafts|draft_tokens|accepted_tokens)_total|spec_decode_num_accepted_tokens_per_pos_total|request_success_total|generation_tokens_total|prompt_tokens_total)' > "$OUT/metrics-$1.txt"; }
miss() { grep -c 'disk-cache-miss' "$ENGINE_LOG" || true; }

echo "start $(date -Is)" > "$OUT/timeline.txt"
snap 00-start
echo "warmup miss before: $(miss)" > "$OUT/jit-miss-counter.txt"
for c in 1 4 8 16; do python3 "$H" --base-url $BASE --model $MODEL --prompt 256 --concurrency $c --repeat 2 --output-tokens 128 > "$OUT/warmup-c$c.log" 2>&1; done
sleep 5; echo "warmup miss after: $(miss)" >> "$OUT/jit-miss-counter.txt"
snap 01-after-warmup

idle=$(python3 ~/exclusivity.py --url http://127.0.0.1:8100/metrics --check-idle --timeout 60); echo "$idle" > "$OUT/exclusivity-start.txt"
start_total=$(echo "$idle" | sed -n 's/^IDLE_OK start_request_success_total=\([0-9.]*\).*/\1/p'); expected=0

printf 'c\toutput_tokens\tmedian_decode_tok_s\tagg_tok_s\tttft_ms\n' > "$OUT/rows.tsv"
for c in 1 4 8 16; do
  python3 "$H" --base-url $BASE --model $MODEL --prompt 256 --concurrency $c --repeat 5 --output-tokens 128 > "$OUT/bench-c$c.log" 2>&1
  dec=$(grep '^FINAL' "$OUT/bench-c$c.log" | sed -E 's/.*= ([0-9.]+) tok.*/\1/')
  agg=$(grep '^trial' "$OUT/bench-c$c.log" | sed -E 's/.*agg=([0-9.]+).*/\1/' | sort -n | awk '{v[NR]=$1} END{print (NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2}')
  ttft=$(grep '^trial' "$OUT/bench-c$c.log" | sed -E 's/.*ttft=([0-9]+)ms.*/\1/' | sort -n | awk '{v[NR]=$1} END{print (NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2}')
  printf '%s\t128\t%s\t%s\t%s\n' $c "$dec" "$agg" "$ttft" >> "$OUT/rows.tsv"; expected=$((expected + c*5))
  snap 02-after-c$c
done
echo "measure miss end: $(miss)" >> "$OUT/jit-miss-counter.txt"
python3 ~/exclusivity.py --url http://127.0.0.1:8100/metrics --verify --start-total "$start_total" --expected $expected --out "$OUT/exclusivity.json" > "$OUT/exclusivity-verify.txt" 2>&1
echo "concurrency done $(date -Is)" >> "$OUT/timeline.txt"

printf 'prompt\treps\tmedian_decode_tok_s\tmin\tmax\tmedian_ttft_ms\n' > "$OUT/depth.tsv"
for p in 2048 8192 32768 131072; do
  reps=5; [ $p -ge 32768 ] && reps=3
  python3 "$H" --base-url $BASE --model $MODEL --prompt $p --concurrency 1 --repeat $reps --output-tokens 128 > "$OUT/depth-$p.log" 2>&1
  dec=$(grep '^FINAL' "$OUT/depth-$p.log" | sed -E 's/.*= ([0-9.]+) tok\/s \(min ([0-9.]+) max ([0-9.]+)\).*/\1\t\2\t\3/')
  ttft=$(grep '^trial' "$OUT/depth-$p.log" | sed -E 's/.*ttft=([0-9]+)ms.*/\1/' | sort -n | awk '{v[NR]=$1} END{print (NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2}')
  printf '%s\t%s\t%s\t%s\n' $p $reps "$dec" "$ttft" >> "$OUT/depth.tsv"
  snap 03-after-depth$p
done
echo "depth done $(date -Is)" >> "$OUT/timeline.txt"

python3 "$HERE/harness/eugr-remaining-cells-v2.py" --base-url $BASE --model $MODEL --cells prompt --reps 5 --out "$OUT/prompt-effect.json" > "$OUT/prompt-effect.log" 2>&1
snap 04-after-prompt
echo "done $(date -Is)" >> "$OUT/timeline.txt"
