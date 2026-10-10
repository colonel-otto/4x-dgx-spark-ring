# 4x DGX Spark — switchless dual-rail RoCE ring

Four DGX Sparks (GB10, 4 x 128 GB) in a switchless ring, dual rail (both ConnectX-7 cards), built to
[alexellis/glm-5.3-flash-4x-dgx-spark-switchless](https://github.com/alexellis/glm-5.3-flash-4x-dgx-spark-switchless).
Successor to the 3-node work in `3x-dgx-spark-mesh-deepseek-v4-0731-flash` and `2x-dgx-spark-glm-5.3-flash`.

```
sparkmain --(164/165)-- spark1 --(160/161)-- spark2 --(166/167)-- spark4 --(162/163)-- sparkmain
```

Status (2026-10-09): ring up, all 8 links ~109 Gb/s. Results land here as they are measured:

- [x] `fabric/` — per-link RDMA latency/bandwidth, dual-rail, NCCL collectives at 2/3/4 nodes
- [x] `dsv4-0731/` — DeepSeek-V4-Flash-0731 TP=4 (eugr) vs TP=2 / TP=3: RESULTS-TP4-2026-10-09.md
- [ ] `glm-5.3-flash/` — GLM-5.3-Flash NVFP4 TP=4
- [ ] `dsv4.1-flash/` — feasibility of DeepSeek-V4.1-Flash (510 GB) on 4 x 128 GB
