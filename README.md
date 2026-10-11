# 4x DGX Spark — switchless dual-rail RoCE ring

Four DGX Sparks (GB10, 4 x 128 GB) in a switchless ring: 4 DAC cables, each carried by both PCIe x4 halves of the
ConnectX-7 (`enp1s0f*` + `enP2p1s0f*`). Fabric built to
[alexellis/glm-5.3-flash-4x-dgx-spark-switchless](https://github.com/alexellis/glm-5.3-flash-4x-dgx-spark-switchless)
(fabric + switchless NCCL only; model recipes are per folder below).
Successor to the 3-node work in `3x-dgx-spark-mesh-deepseek-v4-0731-flash` and `2x-dgx-spark-glm-5.3-flash`.

```
sparkmain --(164/165)-- spark1 --(160/161)-- spark2 --(166/167)-- spark4 --(162/163)-- sparkmain
```

Status (2026-10-11): ring up, 8 logical links ~109 Gb/s each; serving GLM-5.3-Flash TP=4 on :8100 (DSv4.1 stopped, kept). Results land here as they are measured:

- [x] `fabric/` — per-link RDMA latency/bandwidth, dual-rail, NCCL collectives at 2/3/4 nodes
- [x] `dsv4-0731/` — DeepSeek-V4-Flash-0731 TP=4 (eugr) vs TP=2 / TP=3: RESULTS-TP4-2026-10-09.md;
      4-HCA NCCL A/B (prefill -9 %, `NCCL_VARIANT=4hca eugr-boot-tp4.sh`)
- [x] `glm-5.3-flash/` — GLM-5.3-Flash TP=4: alexellis recipe (c1 91–105, c16 176) and **LVKP build, serving since 2026-10-11 evening** (c1 112–118, c16 ~300, 131K in 40 s, qeval 72/75); RESULTS.md
- [x] `nccl-4hca/` — ondigo 4-HCA NCCL patch: all-reduce 105 -> 186 Gb/s (both PCIe halves), gate scripts
- [x] `dsv41-flash/` — DeepSeek-V4.1-Flash TP=4 (MiaAI SGLang production line + RoCEnante over the sparkring mesh):
      RECIPE.md (what we took from whom, our deltas, bring-up), RESULTS.md (c1 129 tok/s, 131K in 24 s, qeval 72/75, 1M ctx)

## Third-party material

`nccl-4hca/nccl-2.30.7-switchless-4hca.patch` is from [ondigo-winder/SWITCHLESS-NCCL-RING-4-GB10](https://github.com/ondigo-winder/SWITCHLESS-NCCL-RING-4-GB10)
(Apache-2.0). `dsv41-flash/recipe/miaai-sparkmain-ring.patch` and the generated `ring-mesh/` scripts derive from
[MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks) and
[FujitsuPolycom/sparkring](https://github.com/FujitsuPolycom/sparkring); they remain under their projects' licences.
Fabric and switchless NCCL: [alexellis/glm-5.3-flash-4x-dgx-spark-switchless](https://github.com/alexellis/glm-5.3-flash-4x-dgx-spark-switchless),
[alexellis/switchless-nccl](https://github.com/alexellis/switchless-nccl). Addresses in this repo are private LAN / point-to-point fabric ranges.
