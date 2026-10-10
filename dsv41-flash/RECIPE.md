# DeepSeek-V4.1-Flash, TP=4 on the 4-Spark switchless ring: the recipe as built (2026-10-10)

What each upstream gives us, and what we added:

| Layer | Source | What it contributes here |
|---|---|---|
| Fabric: cabling, per-cable /24s, MTU 9000, GID 3, runtime-only setup | [alexellis/glm-5.3-flash-4x-dgx-spark-switchless](https://github.com/alexellis/glm-5.3-flash-4x-dgx-spark-switchless) (`docs/fabric.md`) → our `~/fabric-ring-up.sh` | The ring itself. **Nothing model-specific**: its serving recipe is GLM-5.3 on vLLM. |
| NCCL that can run np=4 on a ring | [alexellis/switchless-nccl](https://github.com/alexellis/switchless-nccl) v0.0.1 (NCCL 2.30.7 + SparkRing skip-tree/PAT + listener GIDs, hardened) | Ring-only NCCL, but capped at **2 HCAs** = half of every cable. |
| Both PCIe halves of every cable | [ondigo-winder/SWITCHLESS-NCCL-RING-4-GB10](https://github.com/ondigo-winder/SWITCHLESS-NCCL-RING-4-GB10) `nccl-2.30.7-switchless-4hca.patch` on top of v0.0.1 | 4 HCAs: all-reduce 105 → 186 Gb/s. See `../nccl-4hca/RESULTS.md`. |
| The DSv4.1 serving engine | [MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks) `start-tp4.sh`, `Dockerfile.canary-roce`, TP4 production line (`docs/tp4.md`) | SGLang dsv4.1 branch + RoCEnante + b12x_next, EP=1, DSpark k=5, packed NVMe Engram, prefill SP, fast loader, 1M context. |
| Opposite-node paths for RoCEnante | [FujitsuPolycom/sparkring](https://github.com/FujitsuPolycom/sparkring) `cx7_hairpin_diagonal` @ `f16b5f4`, via MiaAI `scripts/ring_mesh/` | Neighbour NICs forward opposite-node RDMA in hardware, so RoCEnante's one-shot collectives work on a ring. "Research-only" upstream. |

## Our deltas from MiaAI's ring instructions

1. **NCCL library**: ondigo 4-HCA build (`/opt/nccl-switchless-4hca`, sha256 `1c0dc70a…`) instead of sparkring's
   dual-PCI-domain build. No `NCCL_IB_EXTENDED_IPV4_GIDS` / `PRESERVE_PCI_DOMAIN` flags needed. Every rank must run it.
2. **Weights over NFS, not local copies** (MiaAI's ring was tested with `NFS_SHARE=0` + full local copies; no worker here
   has 476 GB free). Head reads `~/models/DeepSeek-V4.1-Flash`; each worker gets a docker volume `dsv41-weights` of
   `type=nfs` from sparkmain over the fabric (spark1 → 10.100.164.2, spark4 → 10.100.162.2). We run the launcher with
   `NFS_SHARE=0`, so it only checks the volumes. **spark2 is the opposite node** (no cable to sparkmain): /32 routes send
   its NFS through spark1 (kernel forwarding is already on and `DOCKER-USER` accepts fabric ports). 889 MB/s vs 110 MB/s
   on the 1 GbE LAN. Load takes ~120 s per rank with the fast loader.
3. **Engram packs built once on sparkmain** for all 4 ranks (`pack_engram.py --rank r --tp 4`, ~47 GiB per rank, ~4 min
   in parallel) and rsynced over the fabric to `/opt/dsv41-4x-spark/engram` on each worker. Never over NFS: MiaAI measured
   ~11 ms/step for unpacked NFS Engram.
4. **Launcher patch** (`recipe/miaai-sparkmain-ring.patch`, against MiaAI `MIAAI_COMMIT`): our workers have different
   usernames, so `WORKER_USER=""` lets `~/.ssh/config` pick per host; spec-table push uses SSH aliases not IPs.
   `WORKER_DIR=/opt/dsv41-4x-spark` (same absolute path on every worker).
5. **Image built once** on sparkmain (`docker build -f Dockerfile.canary-roce`, ~3 min, all in-image tests pass),
   copied with `docker save | ssh docker load` over the fabric.
6. **Mesh at the default `hairpin_queue_size` 1024**: no devlink re-init; RoCE cap 81,920 B (every c1 decode collective
   is 50–60 KB). Installed **runtime-only** (marker unit in `/run/systemd/system`), re-applied by `dsv41-ring-up.sh`.
7. `DSV41_SERIAL_WEIGHT_LOAD` left off (production line uses the fast loader's own pacing). Port 8100.

## Bring-up from scratch (in order)

```bash
~/fabric-ring-up.sh                                   # fabric (after any reboot)
# NCCL: build ondigo 4-HCA on top of switchless-nccl v0.0.1 (../nccl-4hca), install to /opt/nccl-switchless-4hca on all 4
git clone https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks ~/dsv41/miaai
cd ~/dsv41/miaai && git apply <repo>/dsv41-flash/recipe/miaai-sparkmain-ring.patch
cp <repo>/dsv41-flash/recipe/env.tp4 .env.tp4
docker build -f Dockerfile.canary-roce -t dsv41-4x-spark:canary-roce .
for h in spark1@10.100.164.1 spark4@10.100.162.1 spark2@10.100.160.1; do docker save dsv41-4x-spark:canary-roce | ssh $h docker load; done
# Engram: pack 4 ranks on sparkmain into ~/dsv41-engram, rsync r1/r2/r3 to /opt/dsv41-4x-spark/engram on spark1/spark2/spark4
# workers: mkdir /opt/dsv41-4x-spark/{state,logs,engram}; docker volume create dsv41-weights (type=nfs, see env.tp4 notes)
# mesh: build sparkring marker (sha256 src 8684a696…, binary 2828c07e…) to /opt/dsv41-mesh/bin on all 4;
#       python3 scripts/ring_mesh/plan.py --sparkring ~/dsv41/sparkring --out ~/dsv41/ring-mesh sparkmain spark1 spark2 spark4
~/bin/dsv41-ring-up.sh                                # exports, spark2 routes + mount, mesh (engine stopped)
./start-tp4.sh doctor && ./start-tp4.sh serve         # ~6 min to "Ready: API on port 8100"
./start-tp4.sh stop
```

Boot log must show: `SWITCHLESS/4HCA: listener slot 0..3` (NCCL on 4 HCAs), `RoCEnante ready: world=4
hcas=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1`, `DSV41_L2_PREFETCH: RoCE collectives prefetch`,
`[moe_b12x_next] armed`, `max_total_num_tokens=6.4–6.7M`.

Rollback: NCCL-only line = `cp ~/dsv41/miaai/.env.tp4.nccl-only .env.tp4` (also kept commented in env.tp4), then
`sudo /opt/dsv41-mesh/mesh-down.sh` on each node with the engine stopped (re-run step 2 of `dsv41-ring-up.sh` after,
since mesh-down also deletes the spark2↔sparkmain routes).

## Compared with other DSv4.1 4×GB10 recipes

- **MiaAI TP4 production line** (switched fabric, and the ring+mesh variant in `docs/switchless-ring.md`): this *is* our
  engine; our numbers sit at their ring+mesh level (qeval 79.8–82.3 vs 81.8–85.9; real-text prefill 4.4–4.8k vs 4.8–5.0k
  switched). Same qeval failures (`code_interval_intersect`, `json_escape`, `math_m9`).
- **[ZackO2o/DeepSeek-V4.1-Flash-4x-GB10-1M-Full-Recipe](https://github.com/ZackO2o/DeepSeek-V4.1-Flash-4x-GB10-1M-Full-Recipe)**
  (docs + probes only, issue #1, PR #2): lane A is vLLM (tonyd2wild patches, C1 ~51, prefill ~1.45k tok/s, KV 1.5–1.9M);
  lane B is the same MiaAI SGLang stack on a ring with **RoCEnante off and 2 HCAs** (C1 104 idle/long-answer, 131K in
  29.7 s). Ours is ahead on every comparable cell (indicative: different harnesses). Things we took / tested from it:
  - `DSV41_CACHE_GIB=0` (their +9 % KV): **tested here, not adopted** — KV +3.6 %, real-text prefill and c1 unchanged,
    c16 aggregate −6 %, repetitive-text prefill −10–14 %. Kept 4 GiB.
  - Natural-text prefill measurement (their/MiaAI#21 point that repeated filler inflates the Engram cache): adopted,
    `realtext_ttft.py`.
  - Not applicable: vLLM `gpu_worker_cachefix`, gmu tuning, NVMe KV prefix tier (vLLM connector only), 2-HCA advice.
  - Not yet tested: re-detecting the GID index at boot (we hard-code 3; `fabric-ring-up.sh` fixes GID holes), clock
    pinning (`-lgc`; ours already run ~2.4–2.5 GHz), their NCCL flag set (never isolated in their A/B).
