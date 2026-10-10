# PLAN-TP4 — TP=4 launch recipes for the 4-Spark ring (DRAFT, nothing executed)

Drafted 2026-10-09 on sparkmain, read-only. No container, docker or nvidia job was started; no config was
changed; no network load was generated (read-only `ssh ... ls/du/ip`, one HF metadata query). Every command
below is a proposal. Run the fabric-latency gate (section 3.1) only after the other agent's fabric benchmark
has finished.

Ring (rank order = ring order, rank 0 = sparkmain):

```
r0 sparkmain --(164/165)-- r1 spark1 --(160/161)-- r2 spark2 --(166/167)-- r3 spark4 --(162/163)-- r0
```

Ranks MUST follow ring adjacency (0-1, 1-2, 2-3, 3-0). Non-adjacent pairs (0-2, 1-3) have no RDMA path.

---------------------------------------------------------------------------------------------------

## 0. Findings that change the plan (read first)

1. **The "matched 2v3" study was not run on the eugr engine.** `docs/RESULT-2V3-MATCHED-2026-08-30.md`
   used the anemll image (`dsv4-3spark:0.1.1`, vLLM 0.25.x, MTP K=2, `nvfp4_ds_mla` KV, seqs 32, util 0.835)
   with `scripts/decode_depth_sweep.py` + `scripts/benchmark_mtp_concurrency.py`. The eugr engine has only a
   lighter 2-node and 3-node record from `bench-miaai.py` (n=5), in
   `docs/RESULT-2V3-CROSS-ENGINE-PARITY.md`. eugr cannot run MTP K=2 (checkpoint
   `dspark_block_size=5`, engine refuses nst<5) and cannot do `nvfp4_ds_mla` KV. So "run the TP=4 arm
   identically" is possible in two separate ways, and I give both:
   - **Track A (eugr, what you asked for)**: compare to the eugr TP=2/TP=3 `bench-miaai` numbers.
   - **Track B (anemll, the only way to extend the powered n=30 study)**: same engine as the matched study.
2. **The TP=3 baselines were measured on the old triangle** (driver 580.173, 2026-08-30/31). A 3-rank NCCL
   ring now needs a closing edge sparkmain-spark2 that no longer exists, so TP=3 cannot be re-measured
   same-session on the ring. TP=2 can (any adjacent pair). Use a same-day TP=2 control as the drift check.
3. **The `/tmp/dsv4` copy on spark2 is already complete.** `/tmp/dsv4/hf-DeepSeek-V4-Flash-0731` on spark2:
   156 GB, 48 safetensors, `ls -l` sizes byte-identical to sparkmain (checked). The "spark4 re-exports to
   spark2" step is not needed. spark1 has no local copy (NFS-only) and only 111 GB free, so it cannot hold 156 GB.
4. **sparkmain's LAN port is 1 Gb/s** (`ethtool enP7s7` = 1000 Mb/s; `eugr-boot.sh` comments say 10G).
   Bulk copies over the LAN take ~22 min per 156 GB. Do bulk copies over the rails, control traffic on the LAN.
5. **Upstream's HF revision differs from ours.** Upstream pins `LibertAIDAI/GLM-5.3-Flash-NVFP4@9e0d74e3`;
   our cache is `caca4e6a` (current main, modified 2026-08-30). Per HF tree diff, all 120 weight shards are
   identical; only `config.json`, `model.safetensors.index.json`, `chat_template.jinja`, `README.md` differ and
   `model-input-scales.safetensors` is new in `caca4e6a`. See 4.2 for how to pin.
6. **A stock NCCL will not form on a bare ring.** Upstream (`docs/recipe.md` section 2) needs the patched
   NCCL 2.30.7 "skip-tree-connect" (`LD_PRELOAD` + `NCCL_SKIP_TREE_CONNECT=1` + `NCCL_SWITCHLESS_RING_ONLY=1`
   + `NCCL_ALGO=Ring`). Our 3-node runs never needed it (triangle = full mesh). It is a hard prerequisite
   for every TP=4 job here, DSv4 included. `~/nccl` (2.30.7) on sparkmain is a stock build (no skip-tree
   symbol found), so fetch the release with upstream `scripts/install-switchless-nccl.sh`.

---------------------------------------------------------------------------------------------------

## 1. Prerequisites per node

### 1.1 Facts table

| rank | node | LAN (master/bootstrap, `enP7s7`) | f0 (-> next rank) | f1 (<- prev rank) | local DSv4-0731 | GLM NVFP4 + DFlash2 | free disk |
|---|---|---|---|---|---|---|---|
| 0 | sparkmain | 192.168.1.70 | `enp1s0f0np0` 164.2 / `enP2p1s0f0np0` 165.2 -> spark1 | `enp1s0f1np1` 162.2 / `enP2p1s0f1np1` 163.2 <- spark4 | `~/dsv4/hf-DeepSeek-V4-Flash-0731` (156G) | HF cache | 1.9T |
| 1 | spark1 | 192.168.1.6 | 160.2 / 161.2 -> spark2 | 164.1 / 165.1 <- sparkmain | **none**; NFS `/mnt/sparkmain/dsv4-0731` via 10.100.164.2 | HF cache | **111G** |
| 2 | spark2 | 192.168.1.66 | 166.1 / 167.1 -> spark4 | 160.1 / 161.1 <- spark1 | `/tmp/dsv4/hf-DeepSeek-V4-Flash-0731` (156G, complete) | HF cache | **70G (93% full)** |
| 3 | spark4 | 192.168.1.76 | 162.1 / 163.1 -> sparkmain | 166.2 / 167.2 <- spark2 | **none yet** | **none yet** | 822G |

Every node has f0 pointing at the next rank and f1 at the previous one, so the NCCL HCA list is identical on
all four nodes (unlike the 2x repo, where it had to differ per rank). Device names: card 1 `rocep1s0f0/f1`,
card 2 `roceP2p1s0f0/f1`. spark4 has no `/opt/eugrcache-*` dirs yet (cold JIT caches, see 5.7).

### 1.2 Images to copy to spark4 (spark4 has no images)

| image | use | size | source |
|---|---|---|---|
| `eugr/spark-vllm-b12x:latest` (digest `sha256:7dc02f162929...`, vLLM `0.1.dev20133+gb5f995e73`, torch 2.13+cu130, FlashInfer 0.6.18) | DSv4 Track A | ~24.9 GB | from sparkmain; **pin by digest**, `:latest` moves. Recipes also name `vllm-node-b12x`; confirm it is the same image ID (`docker images --digests` on each node) |
| `dsv4-3spark:0.1.1` (anemll) | DSv4 Track B | `~/images/dsv4-3spark-0.1.1.tar` on sparkmain | `docker load` on spark4 |
| `ghcr.io/tonyd2wild/vllm-glm53-flash:sm121-v11-dflash2` (digest pinned in upstream `rank-launcher.sh`: `@sha256:4def0ef6...`) | GLM arm A | not stated | `docker pull` on all four, or pull once + `docker save \| ssh docker load` |
| `glm53-flash-dflash:gb10tile` (our SGLang) | GLM arm B | not measured | `docker save` from sparkmain -> spark4 |

Copy path: `docker save IMG | ssh spark4@10.100.162.1 docker load` goes over rail 162 (first `ssh -o
StrictHostKeyChecking=accept-new` once). LAN copy also works (~3.7 min for 25 GB at 1 Gb/s) and does not touch
the fabric, so it is the safe choice while the fabric benchmark is still running. Verify equality by layer
identity, not image ID (containerd vs overlay2 IDs differ): use `image_ident` in
`~/glm53-tensorfold/scripts/nodes.sh`.

Also needed on every node: `~/nccl-switchless-v0.0.1/libnccl.so.2` (+ `.2.30.7`), SHA-256 `78cb8387...` via
upstream `install-switchless-nccl.sh` (needs internet; alternatively fetch once and rsync over the LAN).

### 1.3 Weights and mounts

**DSv4-0731** (all four nodes need the same host path because `run-recipe.py -v` applies to every node):
`-v /tmp/dsv4:/models/dsv4host` with a real directory `/tmp/dsv4/hf-DeepSeek-V4-Flash-0731` (Docker rejects a
symlink bind source; `eugr-boot.sh` makes a hardlink farm with `cp -al`, which only works on the same fs).

| node | how `/tmp/dsv4/hf-DeepSeek-V4-Flash-0731` is provided |
|---|---|
| sparkmain | hardlink farm from `~/dsv4/...` (what `eugr-boot.sh` already does) |
| spark2 | already a real 156G copy; use as is |
| spark4 | **local copy**: `sudo mkdir -p /tmp/dsv4`, then `sudo mount -t nfs -o ro,vers=4.2,nconnect=8,rsize=1048576 10.100.162.2:/home/sparkmain/dsv4/hf-DeepSeek-V4-Flash-0731 /mnt/sparkmain-dsv4` then `cp -a` to `/tmp/dsv4/hf-DeepSeek-V4-Flash-0731`, then unmount. The export to 10.100.162.1 already exists in `/etc/exports` |
| spark1 | `sudo mount --bind /mnt/sparkmain/dsv4-0731 /tmp/dsv4/hf-DeepSeek-V4-Flash-0731` (existing NFS mount via 10.100.164.2). Docker `-v` rbinds, so the submount is visible. Cold-load cost: see 5.3. To make it local, free ~45 GB first (spark1 holds 126 G + 99 G of Qwen3.8-Flash-Next caches; your call, I deleted nothing) |

`~/eugr-boot.sh` precondition runs `cp -al $HOME/dsv4/...` if the directory is missing, which would fail on
spark1/spark4; make the dirs first so it is skipped.

**GLM-5.3-Flash NVFP4** (182 GB, 120 shards) + DFlash2 drafter (2.2 GB): present in the HF cache on
sparkmain, spark1, spark2 (all `caca4e6a`, drafter `bf582e4e`). For spark4: sparkmain already exports
`/home/sparkmain/.cache/huggingface` read-only to 10.100.162.1; NFS-mount via 10.100.162.2 and `cp -a` the
two model dirs (or `hf download` with a token from the internet). Needs 185 GB of the 822 GB free.

### 1.4 NCCL / runtime env (identical on all four ranks unless noted)

```
NCCL_SOCKET_IFNAME=enP7s7  GLOO_SOCKET_IFNAME=enP7s7  TP_SOCKET_IFNAME=enP7s7  VLLM_HOST_IP=<node LAN IP>
NCCL_NET=IB  NCCL_IB_DISABLE=0
NCCL_IB_HCA==rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1     # '=' exact match; all 4 devices, f0 first
NCCL_IB_GID_INDEX=3  NCCL_IB_SUBNET_AWARE_ROUTING=1  NCCL_IB_MERGE_NICS=0  NCCL_NET_PLUGIN=none
NCCL_CROSS_NIC=1  NCCL_CUMEM_ENABLE=0  NCCL_IGNORE_CPU_AFFINITY=1  NCCL_BUFFSIZE=16777216
# switchless ring (patched NCCL, from upstream docs/recipe.md section 4):
LD_PRELOAD=/opt/patched-nccl/libnccl.so.2  VLLM_NCCL_SO_PATH=/opt/patched-nccl/libnccl.so.2
NCCL_SKIP_TREE_CONNECT=1  NCCL_SWITCHLESS_RING_ONLY=1  NCCL_ALGO=Ring  NCCL_PROTO=LL,LL128,Simple  NCCL_P2P_LEVEL=SYS
# mount: -v $HOME/nccl-switchless-v0.0.1:/opt/patched-nccl:ro
```

- **`--master`/`--master-addr` = `192.168.1.70` (sparkmain LAN), not a fabric address.** The LAN is the only L3
  network all four share. A fabric address only reaches that node's two ring neighbours: this is exactly how
  `glm53-flash-tf` hung on 2026-10-09 (`/v1/models` 200, chat hung, rank 1 `c10d waitForInput timed out`).
  Upstream does the same (management LAN for rendezvous/bootstrap, RoCE for collectives). `launch-cluster.sh`
  already uses `HEAD_IP` = first `-n` entry and `ETH_IF`=`enP7s7` (autodiscover prefers it), so passing the four
  LAN IPs in ring order gives this for free; `--master-port` default 29501 (GLM upstream uses 29520).
- **HCA list / GID**: all 4 devices (dual rail) matches the 3-node eugr practice (`eugr-boot.sh`). Upstream
  validated 2 devices (card 1 only). Treat 2 vs 4 HCAs as a recorded A/B, not a silent choice. Do not rewrite
  `/etc/nccl-ib-hca` (old recipes read it; spark2/spark4 have none). `NCCL_IB_GID_INDEX=3` was not set by
  `eugr-boot.sh` (NCCL auto-picked); pin it now and run the GID check in `~/fabric-ring-up.sh` first
  (all 16 HCAs RoCE v2, non-zero idx 3).
- `NCCL_TIMEOUT=3600` in `eugr-boot.sh` is the reason a wedged rank is silent for an hour. For bring-up use a
  watchdog (section 2.4) instead of trusting the 1 h timeout.
- Pre-flight on every node: `~/fabric-ring-up.sh` has been run since last boot; MTU 9000 on all 16 ports
  (`ping -M do -s 8972` on every edge); no stray `vllm_node`/`sglang_node`/`glm53*` container or GPU process
  on any of the four (names are identical across nodes; check each, do not broad-`pkill`); `free -g` and
  GPU-memory headroom on spark4 (newer OS may have a different resident baseline; util above ~0.828 fails on a
  warm box).

---------------------------------------------------------------------------------------------------

## 2. DSv4-0731 TP=4 on the eugr engine (Track A)

### 2.1 Is the TP=3 padding patch involved? Divisibility check

There are two different things called "the TP=3 padding":

| artifact | where | at TP=4 |
|---|---|---|
| `patches/apply_tp3_patch.py` (+ `VLLM_DSV4_TP_PAD`) | anemll image only. **Never applied to eugr** (`docs/ENGINE-AB-3NODE.md`: "DO NOT apply our TP=3 padding patch to this image", 6/15 anchors MISS) | Nothing to remove. It is a no-op for TP 1/2/4/8 (`pad_heads_for_groups(64,4,8)==64`; `_SUPPORTED_PAD_TP=(3,)`) and fails closed for other sizes that need padding |
| eugr image's native `virtual_tp` (`vllm/config/virtual_tp.py`, flag `--exp-b12x` in `build_args`) | `[virtual_tp.py:527] Automatically enabled B12X virtual TP padding` printed at TP=3 (heads 64->72, groups 8->9, MoE 2048->2112, vocab 129280->129408) | It is automatic, not a recipe knob. At TP=4 nothing needs padding, so it **should stay off**. Unverified in this image: I cannot run it. The check is "the log must NOT contain `virtual TP padding`" |

Divisibility by 4 (from `config.json` of `hf-DeepSeek-V4-Flash-0731`): heads 64 -> 16/rank; `o_groups` 8 ->
2/rank (heads-per-group stays 8); `index_n_heads` 64 -> 16; `moe_intermediate_size` 2048 -> 512 (multiple of
128 and of the FP4 block); 256 routed experts / 4 = 64 (only matters if EP were on, it is not); vocab 129280
-> 32320; `hidden_size` 4096. All divide. The third-party TP=4 repo (tonyd2wild, reviewed and dismissed in
`HANDOFF-ENGINE-CLONE-REVIEW-2026-08-28.md`) reaches the same conclusion ("at TP=4 everything divides").

Real unknown, not divisibility: 16 local heads and 512-wide expert shards are smaller than anything the
`B12X_MLA_SPARSE` attention / b12x MoE kernels have run here (TP=2: 32 heads, TP=3: 24). A kernel assert at
first boot is plausible. Contingency: PP=2 x TP=2 over pairs (sparkmain+spark1) and (spark2+spark4) with the PP
hop on spark1->spark2 (edge 160/161), which needs only point-to-point on adjacent nodes (the old PP3 result in
`docs/PP3-PIPELINE-PARALLEL.md` was poor, so this is a fallback, not a goal).

### 2.2 What changes from the TP=3 launcher

New recipe `~/eugr-launcher/recipes/dsv4-flash-0731-local-tp4.yaml` = copy of `dsv4-flash-0731-local-tp3.yaml`:

```diff
-name: DSV4-Flash-0731-local-TP3
+name: DSV4-Flash-0731-local-TP4
-  tensor_parallel: 3
+  tensor_parallel: 4
   (everything else identical: max_num_seqs 16, mnbt 8192, util 0.85 -> overridden to 0.82 on CLI,
    block_size 256, kv fp8, dspark nst 5 probabilistic, mods: instanttensor-hybrid-draft-loader,
    --exp-b12x, env block B12X_*; keep --moe-backend b12x --attention-backend B12X_MLA_SPARSE)
```

New `~/eugr-boot-tp4.sh` = copy of `~/eugr-boot.sh`:

```diff
-NODE0.. NODE2 ; NODES="$NODE0,$NODE1,$NODE2"
+# ~/.eugr-nodes gains NODE3=192.168.1.76 (do not edit it now; export in the new script instead)
+NODES="192.168.1.70,192.168.1.6,192.168.1.66,192.168.1.76"      # ring order == rank order
-for n in $NODE0 $NODE1 $NODE2; do ... precondition ssh ... done
+for n in 192.168.1.70 192.168.1.6 192.168.1.66 192.168.1.76; do ... done
+  # precondition for spark1/spark4: /tmp/dsv4/hf-DeepSeek-V4-Flash-0731 must already exist (1.3)
-BASE_RECIPE=".../dsv4-flash-0731-local-tp3.yaml"; GEN_RECIPE_NAME="dsv4-tp3-nst${NST}-mnbt${MNBT}"
+BASE_RECIPE=".../dsv4-flash-0731-local-tp4.yaml"; GEN_RECIPE_NAME="dsv4-tp4-nst${NST}-mnbt${MNBT}"
-name regex 'DSV4-Flash-0731-local-TP3-nst..' -> '...-TP4-nst..'
 + extra -v / -e for the patched NCCL and ring env of 1.4
-  -e "NCCL_IB_HCA==rocep1s0f0,roceP2p1s0f0,rocep1s0f1,roceP2p1s0f1"   # same four devices; keep, add GID idx
```

Launch command (dry-run first; `eugr-boot.sh` already greps the dry-run for port, names, nst, no duplicate
`--speculative-config`):

```bash
cd ~/eugr-launcher
HF_HOME=/tmp/hfcache nohup python3 run-recipe.py dsv4-tp4-nst5-mnbt8192 \
  -t eugr/spark-vllm-b12x:latest \
  -n 192.168.1.70,192.168.1.6,192.168.1.66,192.168.1.76 \
  -v /tmp/dsv4:/models/dsv4host \
  -v /opt/eugrcache-vllm:/root/.cache/vllm -v /opt/eugrcache-flashinfer:/root/.cache/flashinfer \
  -v /opt/eugrcache-triton:/root/.triton   -v /opt/eugrcache-tilelang:/root/.tilelang \
  -v $HOME/nccl-switchless-v0.0.1:/opt/patched-nccl:ro \
  --no-cache-dirs --gpu-memory-utilization 0.82 --port 8100 \
  -e "NCCL_IB_HCA==rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1" \
  -e NCCL_IB_GID_INDEX=3 -e NCCL_IB_SUBNET_AWARE_ROUTING=1 -e NCCL_IB_MERGE_NICS=0 -e NCCL_NET_PLUGIN=none \
  -e NCCL_BUFFSIZE=16777216 -e NCCL_CROSS_NIC=1 -e NCCL_CUMEM_ENABLE=0 -e NCCL_IGNORE_CPU_AFFINITY=1 \
  -e LD_PRELOAD=/opt/patched-nccl/libnccl.so.2 -e VLLM_NCCL_SO_PATH=/opt/patched-nccl/libnccl.so.2 \
  -e NCCL_SKIP_TREE_CONNECT=1 -e NCCL_SWITCHLESS_RING_ONLY=1 -e NCCL_ALGO=Ring \
  -e NCCL_PROTO=LL,LL128,Simple -e NCCL_P2P_LEVEL=SYS \
  -e NCCL_DEBUG=INFO -e NCCL_DEBUG_SUBSYS=INIT,NET \
  > ~/eugr-tp4-nst5-mnbt8192.log 2>&1 &
```

The launcher starts workers (rank 1..3) first then the head, using `--nnodes 4 --node-rank R --master-addr
192.168.1.70 --master-port 29501`; the LAN IPs in `-n` are also what it SSHes to.

### 2.3 Other scripts that silently assume 3 nodes

- `eugr-service-stop`/`eugr-service-start` and `eugr.service` read NODE0..2 only: **a stop would leave
  `vllm_node` running on spark4**. Do not use the systemd path for TP=4; use the manual nohup above and a
  4-node teardown (`ssh <each> docker rm -f vllm_node`, verify each).
- `quick-validate.sh` (`scripts/eugr-ab/`) asserts the log contains `output groups 8 -> 9`. At TP=4 that check
  must be inverted (assert **absence** of `virtual TP padding`) or it will report a false FAIL.
- `~/fabric_gate_patched.sh` / repo `fabric_gate.sh` are 3-node; a 4-node variant is needed (see 3.1).
- `run_nccl.sh` TOPOLOGY accepts only `direct`(2) and `ring`(3).

### 2.4 Bring-up watchdog (replaces trusting `NCCL_TIMEOUT=3600`)

1. First collective: rank 0 log shows `Connected all rings` / shard-loading progress within 90 s of workers
   starting, else tear down all four and re-run the fabric pre-flight (upstream gotchas.md).
2. Load must keep advancing (GPU memory rising on all four every 15 s); log silence with flat memory = failure.
3. API ready within 30 min cold (4.3 min with warm caches on 3 nodes, ~8 min cold).
4. "Serving" = `/v1/models` **and** one real chat completion returning tokens **and** `quick-validate.sh`
   (TP=4 variant): Paris, 17x23=391, red/blue=7, plus a 30K needle (upstream `gate.sh`). Confirm in the log:
   `NET/IB` on all four ranks (never `NET/Socket`), one NCCL version, no `virtual TP padding`, KV size.
5. Always cycle all four ranks together.

### 2.5 Baselines to compare against (eugr engine, 256-token prompt, 256 output unless noted)

| source | cell | TP=2 (sparkmain+spark1) | TP=3 (triangle) |
|---|---|---|---|
| `results/20260901T174000Z-eugr-tp2-2node/rows.tsv` (TP=2); `results/20260831T1000Z-matched-engine-ab/eugr-c*.log` and `docs/RESULT-2V3-CROSS-ENGINE-PARITY.md` (TP=3) | c=1 decode | 71.9 | 84.7 |
| | c=4 decode / agg | 47.2 / 144.3 | 54.4 / 164.5 |
| | c=8 decode / agg | 37.3 / 218.1 | 44.9 / 249.9 |
| | c=16 decode / agg | 15.7 / 199.9 | 15.0 / 187.4 |
| | c=1 / c=16 TTFT | 302 / 1877 ms | (see log; c=16 2122 ms) |
| `results/20260831T0525Z-eugr-remaining-cells-matched/` | 131K decode / TTFT | OOM (KV 13,107 tok, max len 11,948) | 90.5 / 53.7 s |
| same + parity doc | code-brief / dense-prose | 77.3 / 44.3 | 91.0 / 49.2 |
| TP=2 `context-8k.tsv` | 8K ctx decode | 42.0 (TTFT 3.36 s) | not in this series |
| KV pool | | 13,107 tok | 2,364,598 tok (fp8, util 0.82, max len 1,048,576) |

Config of those arms: image digest `7dc02f16`, DSpark nst=5, mnbt 8192, seqs 16, util 0.82, kv fp8, warm persistent
caches, driver 580.173, 2026-08-30..09-01. A second TP=3 set exists in
`results/20260830T2245Z-eugr-ksweep/` (agg 84.3 / 152.8 / 252.9 / 198.8 at c=1/4/8/16, 128-token window); use the
08-31 matched-engine-ab series as primary. **Do not use `docs/RESULT-EUGR-3NODE-END-TO-END-2026-09-01.md`
as a baseline**: its TP=2/TP=3 numbers (43.1 / 64.9 at 8K) come from another harness, contradict the parity
doc, and the file is garbled.

---------------------------------------------------------------------------------------------------

## 3. Benchmark matrix at TP=4

Rules carried over from the repo: pre-register hypotheses before measuring; tie band 12 % (issue #31), no rep
is discarded, per-rep values and spread published, median never alone; one variable at a time; read config from
the live process (`ps -eo args`), not the env file; `open-webui` on sparkmain stopped for the run;
`exclusivity.py` request-count check; cooldown to <=70 C before each arm; 5 s `nvidia-smi` clock/temp/power
telemetry on all four nodes (GB10 clocks cannot be locked); record image digest, driver and kernel per node.

### 3.1 Fabric-latency sanity gate (before every TP=4 boot; after the other agent's benchmark ends)

1. **Already measured, reuse, do not repeat**: `~/bench/fabric-2026-10-09/lat.tsv` (per link, `ib_write_lat`
   median: 1.42 us @2 B, 2.9 us @4 KB, 8.8 us @64 KB, E1r1..E4r2) and `bw.tsv` (109.1-109.3 Gb/s per link).
2. `~/fabric-ring-up.sh` verification clean: 16/16 HCAs RoCE v2 with non-zero GID idx 3; MTU 9000 on all 16 ports.
3. **Collective latency at decode sizes, 4 ranks** (this is what TP=4 pays ~86 times per token:
   2 all-reduces x 43 layers). Run `~/dsv4/nccl_lat.py` under `torchrun --nnodes 4` inside the same eugr image
   with the section-1.4 env (patched NCCL), engine stopped. It prints us/all-reduce for 8 KiB / 64 KiB / 4 MiB
   and x86 = ms/token. Then repeat on a 2-rank adjacent pair (sparkmain+spark1) as the control.
   Gate (my thresholds, adjust after seeing data): no `NET/Socket`; 8 KiB all-reduce p50 <= ~100 us and no
   sample > 1 ms (ring all-reduce is 2(N-1) sequential hops: 2 at N=2, 6 at N=4; at ~6-10 us/hop NCCL-level
   that predicts 40-60 us); 4-rank x86 budget <= ~8 ms/token.
4. **Bandwidth/MTU sanity**: `nccl-tests` `all_reduce_perf -b 8 -e 256M -f 2 -g 1` on 4 ranks
   (`~/nccl-tests/build` exists; it must be run with the patched NCCL): bus bandwidth at 256 MB >= ~11 GB/s
   (80 % of one 109 Gb/s rail). A much lower figure points to MTU 1500, a merged-NIC pairing, or a single-rail
   fallback. Jumbo ping is necessary, not sufficient.
5. A completed 4-rank collective is the only proof that the ring relays RDMA correctly.

### 3.2 Track A, eugr engine, harness `bench-miaai.py` (byte-identical copy in `~/bench-miaai.py`)

Harness settings of the eugr 2/3-node series: unique cold 256-token prefix, `thinking=false`, `min_tokens =
max_tokens = 256`, `ignore_eos`, median of 5 trials, warm-up first.

Warm-up protocol (`eugr-sweep.sh`): 2 reps at each c in {1,4,8,16} discarded, then check the engine log's
`disk-cache-miss` counter is frozen; if not, 3 more reps at c=1 and 16. This matters more on spark4 (cold caches).

| cell | command shape | notes |
|---|---|---|
| concurrency | `bench-miaai.py --base-url http://127.0.0.1:8100/v1 --model deepseek-v4-flash-eugr-ab --prompt 256 --concurrency {1,4,8,16} --repeat 5 --output-tokens 256` | direct vs 2.5 |
| 8K context | `--prompt 8192 --concurrency 1 --repeat 5` | TP=2 42.0 |
| 131K context | `--prompt 131072 --concurrency 1 --repeat 3` | TP=3 90.5 / 53.7 s TTFT |
| prompt-effect pair | `eugr-remaining-cells-v2.py` (code-brief 18 tok, dense-prose 23 tok, temp 0, max 256) | 91.0 / 49.2 on TP=3 |
| deep concurrency | `eugr-remaining-cells-v2.py` 4 x ~200K, 128 out | TP=3 1.26 tok/s, TTFT 224 s |

Scripts live in `.../3x-dgx-spark-mesh-deepseek-v4-0731-flash/scripts/eugr-ab/` (`bench-miaai.py`,
`eugr-sweep.sh`, `eugr-remaining-cells-v2.py`, `quick-validate.sh`). With TP=4 the extra stress: `max_num_seqs`
is held at 16 for matching (raising it is a separate, labelled arm).

Controls in the same session (so drift and the spark4 driver are separable):

| arm | nodes | why |
|---|---|---|
| C1: TP=2 | sparkmain + spark1 (rail 164/165) | re-measures the 71.9/47.2/37.3/15.7 row on the new cabling, new day, new fabric state |
| C2: TP=2 | sparkmain + spark4 (rail 162/163) | same shape with spark4 in it; C2 vs C1 isolates the driver 580.178 / kernel 7.0 effect |
| T4 | all four | the target |

Order: C1, C2, then T4 (C1 first, so a drifted baseline is noticed before spending the 4-node boot).
TP=3 stays a historical column (2.2).

Pre-registered hypotheses (my guesses, to be fixed before any run; tie band 12 %):
- H1: c=1 decode at TP=4 is within the tie band of TP=3's 84.7 (more bandwidth per rank, but all-reduce goes
  from 4 to 6 hops). Falsified if |delta| > 12 %.
- H2: aggregate at c=8/16 improves over TP=3 (249.9 / 187.4), the hardest-to-lose case, since KV/weights per
  rank shrink to 3/4. Falsified if TP=4 is below TP=3 by > 12 %.
- H3: 131K TTFT improves over 53.7 s (prefill is compute-heavy; per-rank work drops 25 %), at the cost of
  more all-reduce traffic. Falsified if TTFT is higher.
- H4: KV pool at util 0.82 exceeds 2.36 M tokens (weights ~39 GB/rank instead of ~52).
- H5 (driver): C2 and C1 agree within 12 %.

### 3.3 Track B, anemll engine, the powered matched harness (needed to extend the n=30 study)

Same harness and cells as `scripts/run_matched_2v3_powered.sh`:

| item | setting |
|---|---|
| decode depth | `decode_depth_sweep.py --depths D --max-tokens 256 --warmups 3 --reps N --label tp4`, D:N = 2048:30, 8192:30, 32768:30, 131072:30, 262144:12 |
| concurrency | `benchmark_mtp_concurrency.py --depth 8192 --concurrencies 4,8,16 --reps 15 --max-tokens 256 --warmups 3 --mtp-k 2` |
| asserts | 256-token window (`min_tokens`, `ignore_eos`), `cached_tokens == 0`, unique header per prompt, correctness 17x23=391 before measuring, `exclusivity.py` delta = expected |
| engine config (must equal the matched arms) | `MAX_NUM_SEQS=32 MTP_NUM_TOKENS=2 GPU_MEMORY_UTILIZATION=0.835 MAX_NUM_BATCHED_TOKENS=8192 MAX_MODEL_LEN=1048576 LONG_PREFILL_TOKEN_THRESHOLD=1024 DSPARK_MAX_INFLIGHT_PREFILLS=2 KV_CACHE_DTYPE=nvfp4_ds_mla BLOCK_SIZE=256 VLLM_PREFIX_CACHE_RETENTION_INTERVAL=4096`, image `dsv4-3spark:0.1.1` |
| references | decode TP=3 46.59 / 51.07 / 50.83 / 47.38 / 45.04 tok/s vs TP=2 43.68 / 43.62 / 42.29 / 39.92 / 39.79; agg cc4/8/16 TP=3 41.85 / 49.83 / 54.20 vs TP=2 35.28 / 40.76 / 44.45; KV 4,688,072 (TP=3) vs 2,217,166 (TP=2); TTFT 131K 74.90 s vs 87.50 s |
| stats | Mann-Whitney + 100k-resample permutation + Cliff's delta; same outlier rule (no rep dropped, hi+lo trimmed spread beside the raw) |
| cost | ~1.6 h per arm at that n; 262K alone is ~173 s/rep |

Caveats: (a) the TP=3 column is from the old triangle, driver 580.173; (b) `apply_tp3_patch.py` is a no-op at
TP=4, but the anemll launcher scripts (`scripts/launch_vllm_mp_node.sh`, `config/*.env.example`,
`docker-compose.yml`) are 3-node and need a `node3.env` plus the patched NCCL; (c) spark2 is the TP=2 idle
node in the old study, here all four are active, so telemetry must cover four hosts; (d) engine
`anemll` vs `eugr` are different measurements (see `results/20260831T1000Z-matched-engine-ab/README.md`): do not
mix columns.

---------------------------------------------------------------------------------------------------

## 4. GLM-5.3-Flash NVFP4 TP=4

### 4.1 Engine choice

| option | verdict |
|---|---|
| **A. vLLM, upstream alexellis recipe** (`ghcr.io/tonyd2wild/vllm-glm53-flash:sm121-v11-dflash2`, DFlash2 k=7, marlin MoE, fp8_e4m3 KV, patched NCCL, `mp` executor) | **Primary.** Built for exactly this ring; published TP=4 receipts (`data/rigmark/*tp4*`): code decode 75.2 tok/s, prose 29.8, structured 109.6, C1 agg 50.8, C2 75.2, C4 119.3, cold 64K prefill 2,276 tok/s (image used in that run differs from the public one, README says so) |
| B. SGLang, our `glm53-flash-dflash:gb10tile` + DFlash2 | **Second arm**, only to deconfound engine: our TP=2 baseline (`2x-dgx-spark-glm-5.3-flash/README.md`) is SGLang: c=1 49.9 tok/s, c=8 224.3 tok/s (min/max carried; DFLASH k=8, accept len 2.66). TP=4 divides cleanly (64 heads, 288 experts/4=72, `index_n_heads` 32/4=8, `moe_intermediate` 2048/4=512), so the TP=3 "sharded" overlay is not needed |
| C. TensorFold EXL3 (`~/glm53-tensorfold`) | **Not applicable**: two-rank design (`WORKER=`, `FABRIC_PEER`, `PARALLEL<=4` is requests, not ranks) and a different checkpoint (EXL3) |

Note there is no vLLM GLM TP=2 on our hardware, so A vs our TP=2 is cross-engine. To get a clean node-count
effect run B at TP=4 against the existing B at TP=2; to compare with upstream use A.

### 4.2 Arm A launch (upstream `scripts/rank-launcher.sh`, site edits only)

Model dir: upstream mounts `$HOME/glm53-flash-nvfp4` as a plain directory. HF cache snapshots are symlinks into
`blobs/`, which break in a bind mount. Build the directory from the shared shards with hardlinks (no extra
182 GB) and pin the upstream small files:

```bash
# on each node, after the weights are present locally (spark4: after the copy)
mkdir -p ~/glm53-flash-nvfp4
SNAP=$(echo ~/.cache/huggingface/hub/models--LibertAIDAI--GLM-5.3-Flash-NVFP4/snapshots/caca4e6a*)
for f in "$SNAP"/model-000*-of-00120.safetensors; do ln -f "$(readlink -f "$f")" ~/glm53-flash-nvfp4/$(basename "$f"); done
# then fetch config.json, model.safetensors.index.json (and tokenizer files) of revision 9e0d74e3 into the same dir
```

(`model-input-scales.safetensors` exists only in `caca4e6a`; omit it if using the 9e0d74e3 index.) Verify
SHA-256 of `config.json` between the two revisions and decide which one is the run's identity; record it.
DFlash2 drafter: `~/glm53-dflash2-draft/model.safetensors` from the HF cache (`bf582e4e`).
Chat template: repo `templates/chat_template.jinja` (SHA-256 `0c4099f3...`), checked by the launcher.

Site edits to `rank-launcher.sh` (copy it, do not edit upstream's):

```diff
-MASTER="10.0.0.1"                 +MASTER="192.168.1.70"         # sparkmain LAN, not a fabric IP (1.4)
-MGMT_IF="enP7s7"                  (same)
-IB_HCA="rocep1s0f0,rocep1s0f1"    (first run: keep, = upstream-validated, card 1 only)
                                   (second run: 4 devices; the script hard-asserts exactly 2 HCAs and must be relaxed)
 GID_INDEX 3, MPORT 29520, PORT 8000 (use 8100/8901 to match existing consumers if wanted)
```

Launch order: rank 3 (spark4), 2 (spark2), 1 (spark1) headless, then rank 0 (sparkmain) which opens the API;
ranks follow the ring. The launcher refuses to start if any GPU process exists (stop everything else first),
asserts GID idx 3 / MTU 9000 / IPv4 per HCA, and removes `glm53_tp4` before starting. Serve arguments are
upstream's fixed block unchanged (`--tensor-parallel-size 4 --nnodes 4 --node-rank R --gpu-memory-utilization 0.85
--max-model-len 262144 --max-num-seqs 6 --block-size 2304 --moe-backend marlin --kv-cache-dtype fp8_e4m3
--kv-cache-memory 12884901888 --speculative-config {"method":"dflash","model":"/draft","num_speculative_tokens":7}
--tool-call-parser glm47 --enable-auto-tool-choice --reasoning-parser glm45 --distributed-executor-backend mp`).
Leave the 12 GiB KV cap (a 24 GiB cap caused an unrecoverable OOM hard-hang in upstream). Pull the image by the
pinned digest on all four nodes (internet), or copy from sparkmain over the LAN.

Gate: upstream `scripts/gate.sh` (30K needle + glm47 tool-call + warm decode). Benchmark with
`alexellis/rigmark` using the same comparison id as the receipts (`--extra-body
'{"chat_template_kwargs":{"reasoning_effort":"low"}}'`) so numbers are comparable to upstream (code 75.2,
prose 29.8, C4 119.3, cold 64K 2,276). Use `bench-warm.sh` from the 2x repo only for the in-house SGLang series.

### 4.3 Arm B launch (SGLang TP=4)

Start from `2x-dgx-spark-glm-5.3-flash/scripts/start-glm53.sh` with these changes only:

```diff
-HCA / IFS_ / CTL branch on rank          +one block: NCCL_IB_HCA==rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1,
                                           NCCL_SOCKET_IFNAME=enP7s7 GLOO_SOCKET_IFNAME=enP7s7 TP_SOCKET_IFNAME=enP7s7
-NCCL_IB_MERGE_NICS=1                    +NCCL_IB_MERGE_NICS=0 (+ NCCL_IB_GID_INDEX=3, SUBNET_AWARE_ROUTING=1,
                                           patched-NCCL mount + LD_PRELOAD + SKIP_TREE/RING_ONLY/ALGO=Ring)
---tp-size 2 --nnodes 2                  +--tp-size 4 --nnodes 4 --node-rank R
-DIST_ADDR=10.100.162.2:50051            +--dist-init-addr 192.168.1.70:50051   # LAN master
```

Everything else (mem-fraction 0.92, `--max-running-requests 8`, context 65536, `--kv-cache-dtype bfloat16`,
DFLASH k=8 via `--speculative-num-draft-tokens 8`, `--max-mamba-cache-size 40`, `--chunked-prefill-size 4096`)
stays identical so the delta is node count only. Do not enable fp8 KV (tilelang fp8 decode is gated to ROCm in
our patch). Start workers first, head last; the image must be copied to spark4. The 2x repo's
`docs/FABRIC.md` warning ("do not symmetrize the NCCL block") applied to the old pairwise mesh; on the ring the
block is symmetric because f0/f1 roles are uniform.

---------------------------------------------------------------------------------------------------

## 5. Risks

1. **Driver / kernel mismatch (spark4: 580.178.04, kernel 7.0.0-1019, OS 24.04.5; others 580.173.02, 6.17).**
   Driver is a first-order performance variable on GB10 (r0b0tlab documents ~3.5x between 580.142 and 580.159;
   cited in the matched-2v3 doc). A mixed driver can also change NCCL/RDMA behaviour (mlx5 stack differs on 7.0).
   Mitigation: control C2 (TP=2 with spark4) vs C1; record versions per row; first suspect on any spark4-only
   failure or slow rank; do not upgrade the other three as a side effect.
2. **NFS cold-load** (spark1, and spark4 until the local copy is done). 156 GB per reader; sparkmain's NVMe
   and page cache are shared by up to three readers (own + 2 NFS), and unified memory means page cache competes
   with GPU memory (see the memory note on safetensors mmap RSS; `mods/drop-caches` exists in the launcher).
   Throughput over the rail via NFS/TCP is unmeasured: expect minutes, not seconds, and a slower boot than the
   old local-disk triangle. It does not change steady-state tok/s. Measure a 10 GB `dd` read after the fabric
   benchmark ends; do not do it now. Prefer local copies on all four for measured runs.
3. **Ring vs all-to-all.** vLLM TP for DSv4 is all-reduce (ring-friendly: only neighbour traffic). Anything that
   needs all-to-all or p2p between non-adjacent ranks (expert parallelism, DP-attention + EP, some gather/
   broadcast patterns) has no RDMA path on 0-2 and 1-3. B12X cannot do EP anyway (`EP3-EXPERT-PARALLEL.md`).
   Keep TP-only, no `--enable-expert-parallel`. Ring all-reduce adds latency: 6 sequential hops at N=4 vs 4 at N=3
   vs 2 at N=2, ~86 collectives per decode step, so decode at low concurrency may not improve (H1).
4. **Patched NCCL under a different image.** The skip-tree patch is qualified only with the upstream GLM image.
   The eugr image carries torch 2.13+cu130 with its own NCCL (version not recorded here); `LD_PRELOAD` of 2.30.7
   is probably ABI-compatible but unproven. The 3.1 gate catches it before a 25-minute model boot.
5. **Kernel shape risk at 16 heads/rank and 512-wide expert shards** (2.1). Contingency PP2xTP2, or a different
   image (the community TP=4 recipe uses `aidendle94/sparkrun-vllm-ds4-gb10`, which is outside our harness
   and unaudited).
6. **Silent-failure modes already on record**: MTU 1500 (~2.7x slower, no error), GID idx 3 all-zero, merged
   NICs (`NCCL_IB_MERGE_NICS=0`), jumbo ping passes while RDMA is broken, `/v1/models` 200 while chat hangs,
   `NCCL_TIMEOUT=3600` hiding a hung rank for an hour. `ib_write_bw`-per-link and `fabric-ring-up.sh` checks
   do not substitute for a completed 4-rank collective.
7. **Cold JIT caches on spark4** (`/opt/eugrcache-*` do not exist): create them (777) on spark4, first boot is
   ~8 min and the first reps are contaminated; follow the warm-up/miss-counter protocol, otherwise a
   spark4-only JIT tail looks like a TP=4 slowdown (this already misled the c=16 "cliff" in arm 1).
8. **Memory headroom**: util above ~0.828 fails on a warm box ("Free memory ... less than desired"); keep 0.82.
   After a crash the driver can hold ~100 GiB despite an idle `nvidia-smi` (sparkmain also shows a stale 96 %
   util at 18 W): use `drop_caches` + a fresh `docker run`, never `docker restart`.
9. **Disk**: spark2 70 GB free (93 %), spark1 111 GB free (88 %), each holding ~225 GB of Qwen3.8 caches. A
   second image or a local DSv4 copy on spark1 will not fit without deleting something. Docker's image store is
   on the same disk.
10. **Comparability limits**: baselines are triangle-era (driver 580.173); the eugr TP=2 arm had a 13,107-token KV
    pool (max len 11,948) so TP=2 has no depth cells beyond 8K on eugr; the eugr `:latest` image moves (pin the
    digest); nst>=5 and fp8 KV are permanent eugr deltas vs anemll; `bench-miaai` n=5 with a 12 % tie band
    resolves only large effects; prompt shape alone moves decode 1.65x (carry the prompt in every row).
11. **Thermals**: four nodes stacked heat-soak unevenly (the aborted 2v3 run 1 drifted from 75 to 86 C);
    cool to <=70 C before each arm and keep the telemetry.
12. **Tailscale is not a fallback path** for any of this (MTU 1280); spark4's LAN `.76` can slip, confirm with
    `ip neigh | grep 30:c5:99:bd:3c:91` before launching.

## 6. Open questions

1. Track B (anemll, powered n=30, extends the published study) in addition to Track A (eugr)? Cost ~1.6 h/arm
   plus a 3-node-to-4-node port of the anemll launcher.
2. spark1: free ~45 GB (delete one Qwen cache) for a local DSv4 copy, or accept NFS cold-load?
3. GLM weights identity: keep `caca4e6a` (ours, adds `model-input-scales.safetensors`) or pin upstream
   `9e0d74e3` small files? Needs a config.json diff and a gate run.
4. 2 vs 4 HCAs for the first TP=4 boot of each model (upstream validated 2; our 3-node eugr practice is 4).
5. OK to download the switchless NCCL release (github) and the public GLM image (ghcr) once the fabric
   benchmark finishes?
6. Where did the 1 Gb/s LAN on sparkmain come from (`eugr-boot.sh` says 10G)? Matters for image/weight copies.
