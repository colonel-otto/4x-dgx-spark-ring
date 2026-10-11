# GLM-5.3-Flash NVFP4 TP=4 + DFlash2 on the switchless ring: results (2026-10-11)

Recipe: [alexellis/glm-5.3-flash-4x-dgx-spark-switchless](https://github.com/alexellis/glm-5.3-flash-4x-dgx-spark-switchless)
@ `e2d0839` (`research/`). Serve arguments are verbatim; the site deltas are in `glm-tp4.sh` (LAN master 192.168.1.70,
4-HCA NCCL, port 8100, image pinned by digest). Weights `LibertAIDAI/GLM-5.3-Flash-NVFP4` @ `9e0d74e3` (the recipe pin),
drafter `incoai/GLM-5.3-Flash-DFlash2`. Everything changed on the cluster is listed in `CHANGELOG.md`; driver `run-all.sh`.

Harness: the DSv4.1 cells (`bench.sh` → `bench-glm.py`: temp 0.6, top_p 0.95, exactly 128 output tokens, unique cold
prefix, warm-up discarded), two passes. **One deliberate difference:** GLM-5.3's template cannot turn thinking off
(it ignores `thinking: false`), so every request sends `reasoning_effort: low`. Real-text prefill:
`realtext_ttft_glm.py` (same corpus). Quality: MiaAI qeval through `qeval-glm.py` (same 75 tasks and checkers, run
in a throwaway container).

## Bring-up

| | |
|---|---|
| NCCL | 4-HCA build (`/opt/nccl-switchless-4hca`), all 4 HCAs, 4 channels. Came up first try; the v0.0.1 fallback was not needed |
| boot | launch → first correct chat **790 s** (~13 min: weights, torch.compile, CUDA graphs) |
| KV pool | **1,576,246 tokens** (12 GiB/rank fp8_e4m3, 6.01× the 262K window), identical to upstream |
| gate (upstream `gate.sh`) | **4/4 PASS**: needle at 28,780 tokens retrieved, `glm47` tool call, warm decode 73.6 t/s (upstream band ~69–75) |

## Decode (tok/s; pass 1 / pass 2)

| c | per-stream | aggregate | TTFT (ms) |
|---|---|---|---|
| 1 | 90.6 / 104.8 | 74.2 / 83.1 | 318 / 333 |
| 4 | 54.1 / 56.0 | 161.3 / 152.1 | 775 / 606 |
| 8 | 53.3 / 52.6 | 173.3 / 175.8 | 796 / 786 |
| 16 | 43.0 / 40.6 | 178.1 / 175.6 | 3,786 / 4,182 |

The recipe caps `--max-num-seqs 6`, so c8/c16 queue: aggregate plateaus at ~175 and TTFT jumps at c16. c1 has
a wide spread (min 70, max 97.5 in pass 1) because the DFlash2 drafter accepts more on a numbered word list than on code.
Upstream's ~70–75 t/s and the gate's 73.6 are code decode.

## Prefill (cold, c=1)

| prompt | TTFT pass 1 / 2 | tok/s |
|---|---|---|
| 2K (filler) | 1.09 / 1.10 s | ~1.9k |
| 8K | 3.92 / 3.94 s | ~2.1k |
| 32K | 15.7 / 15.3 s | ~2.1k |
| 131K | 62.9 / 63.0 s | ~2.1k |
| real text ~21–24K | 13.2–13.5 s | 1.6–1.8k |
| real text ~77–94K | 44.4–53.7 s | 1.7–1.8k |

Upstream reports ~1,965 t/s cold 64K prefill, so ours matches.

## Quality

qeval **73/75** (97.3 %), 0 truncated, every task `finish_reason=stop`. Failures: `code_merge_intervals` (assert),
`math_m6` (19.2 vs 11.52). DSv4.1 fails 3 different tasks (72/75). Treat the comparison as indicative, not paired:
GLM ran with `reasoning_effort` low/max where DSv4.1 had thinking off/on, and with +8192 max_tokens.

## Against DeepSeek-V4.1-Flash TP=4 on the same ring (`../dsv41-flash/RESULTS.md`, config B)

| | GLM-5.3-Flash | DSv4.1 |
|---|---|---|
| decode c=1 | 91–105 | **127–132** |
| aggregate c=4 / 8 / 16 | 152–161 / 173–176 / 176–178 | **224 / 282–295 / 405–424** |
| TTFT 8K / 32K / 131K | 3.9 / 15.5 / 63 s | **1.56 / 6.0 / 24.3 s** |
| real-text prefill | 1.6–1.8k tok/s | **4.2–4.8k tok/s** |
| qeval | **73/75** | 72/75 |
| context / KV | 262K / 1.58M | **1M / 6.4M** |
| concurrency cap | 6 (recipe, OOM hard-hang margin) | none hit at 16 |
| boot | ~13 min | ~6 min |

DSv4.1 is faster on every speed cell (about 1.3× at c1, 2.3× at c16, 2.5× on prefill) and has 4× the context.
GLM-5.3 scores marginally higher on qeval and passes the tool-call gate.

## Against other GLM-5.3-Flash Spark results (indicative: different harnesses)

| source | setup | decode c1 | cold prefill |
|---|---|---|---|
| **this run** | 4× ring, 4-HCA NCCL, NVFP4 + DFlash2 | gate code 73.6; harness 91–105 (word list) | ~2.1k (8K–131K) |
| alexellis RigMark, v0.0.1 NCCL (`research/…/data/rigmark`) | same recipe, 2-HCA ring | code 71.3, prose 31.2, structured 109 | 64K 1,965 |
| alexellis RigMark, RedHat NVFP4 checkpoint, static k7 | 4× ring | code 75.2 | 64K **2,276** |
| alexellis RigMark, LibertAI NVFP4, TP=2 | 2× Spark | code 42.6 | 64K 1,905 |
| alexellis `docs/switches.md`, CRS504 100G switch | 4×, single 100G rail | warm decode −15 % | 2.5× slower (~910): **doubtful**, see below |
| [fangkemi](https://github.com/fangkemi/GLM-5.3-Flash-4x-DGX-Spark-TP4) | 4×, vLLM TP4, DFlash2 adaptive | ~85–170 by prompt type | 4K 2,768 |
| [tonyd2wild 4×](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-1M-KV-4x-DGX-Spark) | 4×, day-0, MTP | 36 | — (1.26M KV, 262K ctx) |
| [Mia AI TensorFold](https://mia-ai.net/models/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold) | own EXL3 quant, 4× | 95.2 | — |

On the switch: upstream's own RDMA counters showed the 100G link carrying only 8–10 Gb/s during that prefill, so
bandwidth cannot explain a 2.5× loss; it looks like a configuration problem in that one run. Our own A/B agrees that
link bandwidth barely matters for GLM: 4-HCA NCCL (186 Gb/s all-reduce) vs 2-HCA (105 Gb/s) changed prefill by ~5–7 %.
Other switched-vs-ring reports (MiaAI DSv4.1: 5–10 %) fit that. Expect a switch to land within ~5 % of the ring.

We are at or slightly above the published recipe on every comparable point. The 4-HCA NCCL build shows little gain
for GLM: prefill ~2.1k vs 1,965 tok/s, decode within noise. GLM is latency-bound here, not bandwidth-bound; at TP=2
prefill was already 1,905. The untested lever is the **RedHat NVFP4 checkpoint**: upstream measured +16 % prefill
and +5 % code decode with it.

## Boot time (rank 0, 790 s launch → first chat)

| phase | time | note |
|---|---|---|
| container + engine init | ~30 s | |
| **weight load** | **470 s** | default loader; **each node reads 81–126 GB** (`/proc/<pid>/io`) to keep 46 GB, at 170–270 MB/s. The NVMe reads at 4.9–10.7 GB/s (`dd iflag=direct`), so the loader is the bottleneck |
| drafter load | 5 s | |
| profiling (encoder with 1 video item, TileLang, NCCL symmetric VA) | ~130 s | recipe limits images but not video |
| FlashInfer autotune | 77 s | logs "Saved 0 configs", so it re-runs every boot |
| CUDA graphs (target + dflash2) | 37 s | |
| API + multimodal warmup | ~35 s | |

Plan (each step needs a reboot to verify): (1) save a per-node checkpoint once (vLLM `sharded_state`), so each node
reads exactly its 46 GB, then load it with `fastsafetensors` (ships in the image), aiming at ~1 min instead of ~8;
(2) `"video":0` in `--limit-mm-per-prompt` to skip video profiling (~1–2 min); (3) make the FlashInfer autotune cache
persist (~1 min). Target: ~4–5 min boot.

## Memory and the decode ceiling

Per node: 121 GB usable, ~74 GB in use (46 GB weights + 12 GB KV + drafter, CUDA graphs and runtime), ~45 GB free.
Spare memory does not make decode faster. Each forward pass must read the active weights from LPDDR5x (273 GB/s per
Spark) and do ~90 all-reduces over the ring.

Bytes read per forward pass (checkpoint headers): routed experts 8/288 of 175 GB = 4.9 GB, **attention 12.6 GB (BF16,
left unquantised by this NVFP4 build)**, shared expert 2.2 GB, lm_head ~1.3 GB, other ~1 GB: ~22 GB in all, ~5.5 GB
per node. Ceiling ≈ 273 / 5.5 ≈ 50 passes/s before network latency. DFlash2 accepts ~2–3 tokens per pass, so 74–105 tok/s
is close to the hardware limit. The real lever is attention: 57 % of the bytes per token are BF16 attention weights.
A checkpoint with FP8 attention would cut ~6 GB per pass (~35 % faster decode, estimated); quantised builds such as
RedHat NVFP4 (+5 %) and Mia EXL3 (95 tok/s) point the same way.

## Checkpoint choice: the one we run is not the fastest available

We run `LibertAIDAI/GLM-5.3-Flash-NVFP4` @ 9e0d74e3 (182 GiB): routed experts NVFP4 (175 GB incl. FP8 scales), but
attention (12.6 GB), shared expert (2.2 GB), embed/lm_head (2.5 GB) and the rest (2.0 GB) **left in BF16**. On every
token that BF16 part is ~57 % of the bytes read.

| build (others' measurements) | size | decode c1 | cold prefill | quality |
|---|---|---|---|---|
| ours: LibertAI NVFP4 + upstream recipe | 182 GiB | RigMark-style code ~71–74 | ~2.1k | qeval 73/75 |
| full FP8 (zai-org / dealignai, 328 GB), fangkemi ring | 328 GB | code 50, prose 34 | — | — |
| [fangkemi](https://github.com/fangkemi/GLM-5.3-Flash-4x-DGX-Spark-TP4): nvidia NVFP4 experts + BF16 dense → 8-bit ("lossless8") + FP8 drafter + kernel/RoCEnante stack | ~205 GB source | RigMark code **113.8**, prose 62; sparkDash prose 90, code 124 | **~3.4–3.5k** (16K–128K) | qeval 74–75, KL 0.0285, GSM8K 98.4 %, HumanEval 95.7 % |

A bigger, higher-precision checkpoint that fills more RAM is slower, not faster: full FP8 doubles the expert bytes.
The win is NVFP4 experts with **8-bit dense layers** (fangkemi: −7.5 ms per decode step at 0.25 % output error), plus
their kernel work (certified LM head, dense fast path, prefill package). Their build is switched; they also publish
a switchless FP8 ring profile with RoCEnante, which we already run for DSv4.1.

Disk: the nvidia NVFP4 source (204.5 GB) does not fit on spark1 (107 GB free) or spark2 (121 GB). Build once on
sparkmain (1.2 TB free), save per-rank shards (~50 GB each) and copy one to each node over the fabric. That also fixes
the boot read problem above.

## LVKP build (fangkemi/knapcio) on our ring, 2026-10-11 evening: now serving

nvidia NVFP4 @ `09b04e5e` + lossless8 (8-bit dense, config sha `f14dc13c…` = their accepted build) + FP8 drafter
(`15bc8429…`), their overlay and image (`glm53-roce:v11-b58f34ea`, rebuilt per node), `TRANSPORT=switchless` on our
4-HCA NCCL (RoCEnante off, as their ring mode requires), KV 12 GiB/rank (profile: 24), MAX_SEQS 32. Same harness,
cells and qeval as the baseline above. Raw data: `raw/lvkp-*`, `qeval/qeval-glm53-lvkp.*`, `logs/lvkp/`.

| | baseline (alexellis recipe) | **LVKP** | DSv4.1 (stopped) |
|---|---|---|---|
| boot to first chat | 790 s | **510 s** (cold kernel caches) | ~360 s |
| gate | 4/4, warm code 73.6 | **4/4, warm code 85.8** | — |
| decode c1 (pass 1 / 2) | 90.6 / 104.8 | **111.6 / 117.6** | 127–132 |
| aggregate c4 | 161 / 152 | 167 / 160 | 224 |
| aggregate c8 | 173 / 176 | **239 / 260** | 282–295 |
| aggregate c16 | 178 / 176 | **292 / 301** | 405–424 |
| TTFT c16 | 3.8–4.2 s | **1.75 s** | 1.3 s |
| TTFT 8K / 32K / 131K | 3.9 / 15.5 / 63 s | **2.7 / 9.7 / 40 s** | 1.56 / 6.0 / 24.3 s |
| real-text prefill (21–94K) | 1.6–1.8k tok/s | **2.9–3.25k tok/s** | 4.2–4.8k |
| decode at 2K–131K depth | 65–75 | **79–134** | — |
| qeval | 73/75 (code 24, math 13) | 72/75 (code **25**, math 11) | 72/75 |
| KV pool | 1,576,246 (6.0×262K) | 1,471,796 (5.6×262K) | 6.4M, 1M ctx |

LVKP is +23–30 % decode at c1, +40–70 % aggregate at c8/c16 (MAX_SEQS 32 removes the 6-request cap), and +55–80 %
prefill. qeval is one run; fangkemi reports 2–3 points of run-to-run spread on every stack (74/75 on their switched
fleet), and the three misses are arithmetic (`math_m3`, `math_m4`, `math_m9`). Repeat before reading anything into it.
The gap to DSv4.1 shrank to ~10 % decode, ~30 % at c16, ~35 % prefill.

Not yet tried here: the profile's 24 GiB KV (step 16 → 18 first; hard-hang risk), RoCEnante on the ring (their docs:
"a ring port of glm_roce would be the next step", not done by anyone).

Operations: `cd /opt/glm53/src && ENV_FILE=.env.switchless bash start.sh status|logs|stop`. `stop` **preserves** the
containers (`glm53-switchless-r0..3`). Restart them with `docker start`, peers r3, r2, r1 first and r0 last; a fresh
`serve` refuses while they exist. Rollback to the baseline: stop, `docker stop` leftovers, then `glm-tp4.sh up`.

## Serving state

Left serving on :8100 at 16:07 (user decision: GLM-5.3 replaces DSv4.1). Start/stop: `glm-tp4.sh up|down|status`
(`NCCL_VARIANT=v001` = upstream's exact NCCL). Not under systemd, so it does not survive a reboot. After a reboot:
`~/fabric-ring-up.sh`, then `glm-tp4.sh up`, then check `/v1/models` **and** a chat completion.

## Candidate flags (researched 2026-10-11, newest sources first)

- **knapcio PR #4 (macoto-liu, 2026-09-30/10-01, unmerged; fetched as branch `pr4-ring-roce` @ `3f7173f`):**
  `SWITCHLESS_ROCE_RING=1` + `GLM_ROCE_RING=1` + `SWITCHLESS_ROCE_PEER_HCA_MAPS` = RoCEnante one-shot collectives over the
  sparkring opposite-node mesh (the same mesh our DSv4.1 uses). Reported on a 4× ring: c1 step 34.5/41.2/42.3 ms
  (prose/code/JSON) vs ~45–47 ms NCCL-only; code c1 134; qeval 74–75/75; ring smoke `max_abs_err 0`; prefill −1 to −7 %.
  Merges onto our 3b29b25 with no conflicts. Also revives the L2 prefetch windows B/C/D that are inert on the plain ring.
- **DEVSELECT fails on our ring** (`DEVSELECT_BUILD_FAILED … CUDA error: invalid argument`, rank 0; knapcio issue #3,
  2026-09-30, closed with no fix). Decode runs on the host fallback (README: the feature is worth −0.45 ms, +1.9 % prose c1).
- KV sizing reports: 12 (ours) / 16→14 (FP8 weights, t/382459) / 24 (knapcio default) / 40 GiB safe, 44 GiB OOM-killer
  (issue #9, 2026-10-07, 1M ctx). Capacity only; no speed change.
- Accuracy notes: repetition penalty must stay 1.0 (1.2 gives word salad); `reasoning_effort=high` ≈ `max` quality with
  ~31 % shorter turns (SpaceshipCreative 2026-10-08, not measured here); one `json_schema`/`tool_choice:required`
  request disables draft truncation for the whole batch (issue #7).
- Not applicable / rejected: NVFP4 KV (TP2, MTP only, no DFlash2), W4A4 experts (16–21 % output error), `K_LO=2`,
  `BATCHED_TOKENS=9223`, vLLM v0.31 hybrid (untested whole, switched), EXL3-specific tricks.
- Unverified: matching kernel/driver on spark4 (7.0/580.178 vs 6.17/580.173) claimed large gains by one forum user.

## Before / after: what the LVKP changes bought (same harness, same ring, 2026-10-11)

"Before" = alexellis recipe (LibertAI NVFP4, BF16 dense, stock vLLM flags, max-num-seqs 6). "After" = LVKP (nvidia NVFP4 +
8-bit dense, FP8 drafter, knapcio kernel overlay and flags, max-num-seqs 32). Mean of the two passes; DSv4.1 for reference.
The ring-RoCEnante patch (PR #4) has **not** been measured: no attempt reached model boot.

| | before | after | change | DSv4.1 |
|---|---|---|---|---|
| decode c1, per stream | 97.7 | **114.6** | **+17 %** | 129.4 |
| TTFT c1 (256-tok prompt) | 326 ms | **287 ms** | −12 % | 241 ms |
| aggregate c4 / c8 / c16 | 157 / 175 / 177 | 164 / **250** / **296** | +4 / **+43** / **+67 %** | 183 / 288 / 414 |
| per-stream c8 / c16 | 53 / 42 | 47 / 26 | −11 / −38 % (more streams really run at once) | 54 / 40 |
| TTFT c8 / c16 | 0.79 / **4.0 s** | 0.96 / **1.75 s** | +21 % / **−56 %** | 0.79 / 1.33 s |
| TTFT 2K / 8K / 32K / 131K | 1.1 / 3.9 / 15.5 / 63.0 s | **0.80 / 2.7 / 9.7 / 40.0 s** | **−27 / −32 / −37 / −37 %** | 0.54 / 1.56 / 6.0 / 24.3 s |
| decode at 2K / 8K / 32K / 131K depth | 65 / 71 / 73 / 73 | **107 / 92 / 99 / 106** | +31–65 % | 104 / 106 / 115 / 106 |
| real-text prefill (21–94K) | 1.59–1.77k tok/s | **2.91–3.25k** | **+85 %** | 4.2–4.8k |
| gate warm decode (code) | 73.6 | **85.8** | +17 % | — |
| qeval | 73/75, median 58 tok/s, 186 s | 72/75, **median 78 tok/s, 112 s** | answers +34 % faster | 72/75 |
| boot | 790 s | **510 s** (cold) / ~150 s warm `docker start` | −35 % | ~360 s |

Reading: single-stream decode and every latency figure improved except c8/c16 per-stream speed. That drop is the cap
removal: before, requests 7–16 waited in a queue (hence 4 s TTFT at c16); now all 16 run at once, so each gets a smaller
share but the total and the time to first token are far better. qeval moved by one task within its 2–3-point run-to-run
spread. Over the evening the gap to DSv4.1 shrank from ~25 % to ~11 % on c1 decode, and from 2.3× to 1.4× on c16
aggregate.
