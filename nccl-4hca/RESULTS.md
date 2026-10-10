# 4-HCA switchless NCCL gate — 2026-10-10

Library: NCCL 2.30.7 + switchless-nccl v0.0.1 + `ondigo-winder/SWITCHLESS-NCCL-RING-4-GB10`
(`patches/nccl-2.30.7-switchless-4hca.patch`, sha256 `cdf4df6f…`), built on sparkmain with the repo's
`scripts/build.sh` from `~/nccl` tag v2.30.7-1 (all 4 tree hashes matched).
`libnccl.so.2.30.7` sha256 `1c0dc70a00da7540be4c187921b19f4ffe7525e7b72a04fdc0b138c0d9ddfd1d`,
installed at `~/nccl-switchless-4hca` and `/opt/nccl-switchless-4hca` (+ `/opt/nccl-shadow-4hca`) on all 4 nodes.

Test: host-native (no containers, no MPI), ranks 0..3 = sparkmain, spark1, spark2, spark4, bootstrap over enP7s7.
`gate.sh <label> <v001|4hca> [ITERS]` (all-reduce, `~/nt/allreduce` from the repo's `tests/allreduce.cu`),
`colls.sh` (same, `tests/collectives.cu`). `NCH=` and `XENV=` override channels / extra env.

## All-reduce busbw, 50 iterations, 2 reps each

| config | 1 MiB | 64 MiB | 1 GiB |
|---|---|---|---|
| v001, 2 HCAs (half A), nch=4 | 63–64 | 108–110 | 105–106 |
| v001, nch=4, BUFFSIZE=16M | 59–61 | 95–98 | 101–103 |
| 4hca, 4 HCAs, nch=8 | 35–42 | 155–164 | 182–190 |
| 4hca, nch=8, BUFFSIZE=16M | 36–39 | 164–173 | 157–159 |
| 4hca, nch=16 (1 rep, 20 it) | 24 | 163 | 165 |
| 4hca, nch=8, QPS_PER_CONNECTION=2 (1 rep, 20 it) | 35 | 165 | 183 |
| **4hca, 4 HCAs, nch=4, default buffer** | **60–63** | **185** | **186** |

Gb/s. Winner: 4 HCAs, **4 channels**, no `NCCL_BUFFSIZE`: +75% at 1 GiB, +70% at 64 MiB, no small-message loss.
Upstream author: 193.1 Gb/s (raw RDMA ~196).

Per-PCIe-half RDMA tx on sparkmain (`ports/1/counters/port_xmit_data`), 4hca nch=4 run:
`rocep1s0f0` 46.98 GB, `roceP2p1s0f0` 46.98 GB — exact split. v001 sends everything on `rocep1s0f0`.
(Note: `ethtool tx_bytes_phy` is per physical port, so it shows the same number for both halves.)

## Other collectives, 4hca nch=4, 1 GiB

| op | busbw | check |
|---|---|---|
| all_gather | 176.7 | OK |
| reduce_scatter | 177.6 | OK |
| broadcast (root 0 / 2) | 193.7 / 193.5 | OK |
| reduce (root 0 / 2) | 193.4 / 193.7 | OK |
| send/recv to ring neighbour | 191.1 | OK |
| send/recv two hops (sendrecv2) | `ibv_modify_qp 110` | expected: no cable, ring can't carry it |

No NCCL WARN in any ring-collective run.

## DeepSeek-V4-Flash-0731 TP=4 (eugr), v0.0.1 2-HCA vs 4-HCA

Same image, recipe, harness (`bench-tp4.sh`). Baseline = `dsv4-0731/raw/bench-tp4` (2026-10-09, one pass);
4hca = `raw/bench-tp4-4hca` and `raw/bench-tp4-4hca-rep2`. Exclusivity PASS (145/145) on both 4hca passes, no NCCL WARN.
Boot: `NCCL_VARIANT=4hca eugr-boot-tp4.sh`, up in 6.5 min, `/v1/chat/completions` verified.

| cell | v0.0.1 | 4hca pass 1 | 4hca pass 2 | change |
|---|---|---|---|---|
| TTFT 2K | 805 ms | 761 | 757 | −6% |
| TTFT 8K | 2,933 ms | 2,661 | 2,647 | −9% |
| TTFT 32K | 11,757 ms | 10,593 | 10,627 | −10% |
| TTFT 131K | 52,640 ms | 47,980 | (cache hit*) | −9% |
| decode c=1 | 99.5 tok/s | 108.1 | 108.0 | +9% |
| agg c=4 | 214.8 | 206.2 | 206.7 | −4% |
| agg c=8 | 318.8 | 315.5 | 318.6 | ±0 |
| agg c=16 | 212.4 | 208.6 | 213.0 | ±0 |
| code-brief decode | 110.4 | 112.6 | 113.0 | +2% |
| dense-prose decode | 67.8 | 68.0 | 67.0 | ±0 |

\* the harness nonces are deterministic per cell, so pass 2 resent pass 1's 131K prompt and hit the prefix cache (0.7 s).
Prefill is consistently ~9–10% faster from 8K up. Decode is within noise except c=1 (+9%, two passes) and c=4 (−4%).
Baseline is a single pass, so treat sub-5% deltas as noise.
