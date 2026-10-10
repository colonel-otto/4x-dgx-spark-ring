# DeepSeek-V4.1-Flash TP=4 — results (2026-10-10)

Recipe: `RECIPE.md`. Harness: `bench.sh` = the same `bench-miaai.py` cells as `dsv4-0731/bench-tp4.sh` (thinking off,
temp 0.6, top_p 0.95, exactly 128 output tokens, warm-up discarded), with a per-run `--nonce-base` so reruns never hit the
prefix cache. Two passes per configuration. Quality: MiaAI `scripts/qeval.py` (75 auto-scored tasks, temp 0, c=1), run in
a sandboxed container on spark1. Real-text prefill: `realtext_ttft.py` (source code + docs, unique prefix).

## Configurations

| | A: NCCL only | **B: + RoCEnante mesh (serving)** | C: B with `DSV41_CACHE_GIB=0` |
|---|---|---|---|
| TP collectives | 4-HCA NCCL | RoCEnante ≤80 KB, NCCL above | same as B |
| KV pool (tokens) | 6,647,808 | 6,503,424 / 6,404,864 | 6,738,944 |
| qeval | 72/75, median 73.0 / 76.9 | 72/75, median 79.8 | 72/75, median 82.3 |

All three fail the same 3 tasks as MiaAI's published runs (`code_interval_intersect`, `json_escape`, `math_m9`).

## Decode (tok/s; pass 1 / pass 2)

| c | A per-stream | B per-stream | C per-stream | A aggregate | B aggregate | C aggregate |
|---|---|---|---|---|---|---|
| 1 | 114.8 / 115.7 | **126.7 / 132.0** | 127.9 / 123.9 | 93.4 / 94.2 | 103.1 / 104.9 | 102.9 / 99.5 |
| 4 | 65.2 / 66.9 | 70.8 / 69.7 | 69.8 / 72.9 | 187.8 / 185.3 | 224.0 / 141.4 | 219.3 / 194.0 |
| 8 | 54.3 / 53.0 | 56.8 / 51.4 | 50.4 / 56.4 | 217.3 / 294.0 | 282.0 / 294.5 | 290.7 / 293.3 |
| 16 | 39.0 / 37.7 | 39.9 / 40.8 | 38.3 / 38.4 | 409.7 / 390.9 | **405.1 / 423.6** | 389.4 / 387.6 |

Aggregate at c≥4 is noisy (sampled DSpark acceptance); c1 per-stream and qeval medians are the stable decode signals.
TTFT at c=8/16: A 630 / 1168 ms, B 790 / 1335 ms, C 760 / 1445 ms.

## Prefill (cold, c=1)

| prompt | A TTFT | B TTFT | C TTFT | B tok/s |
|---|---|---|---|---|
| 2K (repetitive filler) | 0.54 s | 0.54 s | 0.58 s | ~3.8k |
| 8K | 1.59 s | 1.56 s | 1.80 s | ~5.3k |
| 32K | 5.98 s | 6.04 s | 6.75 s | ~5.4k |
| 131K | 25.1 s | 24.3 s | 27.6 s | ~5.4k |
| real text ~28K | — | 5.9–6.5 s (4.4–4.8k tok/s) | 6.0–6.2 s (4.6k) | |
| real text ~103–114K | — | 24.4–24.6 s (4.2–4.7k) | 22.3–24.7 s (4.6k) | |

## Against DeepSeek-V4-Flash-0731 TP=4 (eugr vLLM, same harness, 4-HCA NCCL)

| | DSv4-0731 | **DSv4.1 (B)** |
|---|---|---|
| decode c=1 | 108 | **129** |
| aggregate c=4 / 8 / 16 | 206 / 316 / 213 | 183 / 288 / **414** |
| TTFT 8K / 32K / 131K | 2.65 / 10.6 / 48.0 s | **1.56 / 6.0 / 24.3 s** |
| context / KV | 131K-class / 5.4M | **1M / 6.4M** |

## Notes

- Port traffic during qeval (A): `rocep1s0f0` 81.4 GB, `roceP2p1s0f0` 43.7 GB — both PCIe halves carry NCCL traffic,
  ~65/35 rather than the 50/50 of the synthetic gate (several SGLang communicators).
- Opposite-node path check: `ib_write_lat` 61 KB sparkmain → spark2 (`--flow_label=16383`) 10.0 µs typical; spark1's
  tc rule forwarded 32,002 packets in hardware, 0 in software.
- Boot to `Ready` ~6 min (fast loader ~120 s per rank over NFS, CUDA graphs ~50 s).
