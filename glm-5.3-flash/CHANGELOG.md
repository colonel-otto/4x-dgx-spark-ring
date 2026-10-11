# GLM-5.3-Flash TP=4 on the ring: changelog

Every change made to the cluster for this measurement, newest last. Recovery steps:
`~/docs/CLUSTER-NOTES-2026-10-09.md` → "In flight 2026-10-11".

## 2026-10-11

- **Claude Code permissions:** 19 allow rules added to `~/.claude/settings.local.json` (docker run/stop/rm/exec/pull,
  curl, git clone, scp, rsync, python3, `~/dsv41/*`, `~/glm53*`, `~/bin/*`, `./start-tp4.sh`, github WebFetch).
  The user also added the auto-mode rule `"Bash"` to `~/.claude/settings.json` via `/permissions`.
- **Recipe cloned:** `research/glm-5.3-flash-4x-dgx-spark-switchless` @ `e2d0839` (alexellis).
- **Image pulled (all 4 nodes):** `ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef6…` (image id `35c6f70f…`,
  31.2 GB). spark1's pull is done by `run-all.sh` after the offload below.
- **Weights staged (all 4 nodes, no extra disk):** `~/glm53-flash-nvfp4` = `LibertAIDAI/GLM-5.3-Flash-NVFP4`
  @ `9e0d74e3` (the recipe pin), hard links into the HF cache. The cached revision `caca4e6a` has byte-identical
  shards. Only `config.json`, `model.safetensors.index.json`, `chat_template.jinja` and `README.md` differ (fetched
  at 9e0d and hash-checked); `caca4e6a`'s extra `model-input-scales.safetensors` is left out.
  `~/glm53-dflash2-draft` = DFlash2 drafter (hard links). `~/glm53-stage/` holds the staging script and the
  pinned chat template (sha256 `0c4099f3…`). To undo: `rm -rf ~/glm53-flash-nvfp4 ~/glm53-dflash2-draft
  ~/glm53-stage` (hard links only; the HF cache is untouched).
- **spark1 cleanup (user-approved):** removed the exited containers `glm53-{sharded,candidate1,baseline}-rank2-20260913`
  and the image `glm53-flash-dflash:gb10tile` (`36edc0e1…`, an SGLang build from the 2-node work; the other
  nodes still have their own builds under that tag). Freed only 2 GB because of shared layers.
- **spark1 offload (user-approved):** `~/.cache/huggingface/hub/models--local-inference-lab--Qwen3.8-Flash-Next-NVFP4`
  (105.9 GB, 57 files) moved to `spark4:~/offload/spark1-hf-hub/` by `offload-qwen-spark1.sh`. The spark1 copy
  is deleted only if file, symlink and byte counts match (log: `logs/offload-qwen.log`). To move it back, run from
  sparkmain: `ssh spark4 'tar -C ~/offload/spark1-hf-hub -cf - models--local-inference-lab--Qwen3.8-Flash-Next-NVFP4' | ssh spark1 'tar -C ~/.cache/huggingface/hub -xf -'`.
- **Measurement run started 15:07 (detached):** `run-all.sh`. It stops DSv4.1, boots GLM (`glm-tp4.sh`, NCCL 4hca,
  fallback v001), then runs the gate, bench, real-text prefill and qeval, and restores DSv4.1 on exit.
  Progress: `logs/STATUS`.
- **Watchdog started 15:16 (detached, expires 17:16):** `watchdog.sh`. It restores DSv4.1 if `run-all.sh` dies,
  stalls for 75 min, or spark1 drops below 2 GB free. Log: `logs/watchdog.log`.
- **15:20 offload finished:** spark1 and spark4 copies matched (57 files, 50 symlinks, 105,896,010,311 bytes). The
  spark1 copy was removed; 5 root-owned `.no_exist` markers were cleared with sudo. spark1 then had 136 GB free.
- **15:27 end state changed (user decision): GLM-5.3 becomes the serving engine.** `post-swap-to-glm.sh` (detached)
  waits for `run-all.sh` to exit. If the measurements completed and the gate had no FAIL, it stops the restored
  DSv4.1 and boots GLM with the NCCL variant that passed. If not, DSv4.1 stays up. Log: `logs/post-swap.log`
  and `[post-swap]` lines in `logs/STATUS`.
- **15:27 attempt 1 failed before any GLM process ran:** `glm-tp4.sh` was not executable ("Permission denied"; my
  mistake). The orchestrator, its DSv4.1 restore, the watchdog and the swap job were all killed by hand. Logs:
  `logs/attempt1/`, `logs/STATUS.attempt1-chmod`.
- **Bug fixed in `~/dsv41/miaai/stop.sh:70`:** `${WORKER_USER:-zurih}` → `${WORKER_USER-zurih}`. `.env.tp4` sets
  `WORKER_USER=""` (let ssh config pick the user), and `start.sh:68` honours that, but `stop.sh` replaced it with
  `zurih`. Every worker ssh then failed with only a warning, so **`./start-tp4.sh stop` never stopped the
  `dsv41-worker` containers** (spark1/2/4 kept GPU memory). After the fix, `stop` removed all three.
- **Simplified:** `run-all.sh` itself now leaves GLM serving when the gate and a final chat pass. It restores DSv4.1
  only on failure, and `watchdog.sh` treats `GLM-5.3 SERVING` as done. `post-swap-to-glm.sh` was removed.
- **15:29 attempt 2 started** (fresh `logs/STATUS`, watchdog restarted, expires 17:29). 15:30: preflight passed on
  all 4 nodes, ranks 3/2/1/0 launched with NCCL 4hca.
- **15:45 GLM ready** (790 s, NCCL 4hca, first try). **15:46 gate 4/4 PASS.** 15:46–16:04: two bench passes and
  real-text prefill. 16:04–16:07: qeval 73/75.
- **16:07 GLM-5.3 left serving on :8100** (`glm53_tp4` on all 4 nodes). DSv4.1 is stopped; its containers are
  removed but its images, weights and NFS volume are kept (`cd ~/dsv41/miaai && ./start-tp4.sh serve` brings it back
  after `glm-tp4.sh down`). Results: `RESULTS.md`.
- **16:40 download started (sparkmain only, detached):** `nvidia/GLM-5.3-Flash-NVFP4` @ `09b04e5e` → `~/models/nvidia/GLM-5.3-Flash-NVFP4`
  (`download-nvidia-nvfp4.sh`, log `logs/download-nvidia-nvfp4.log`). Revision chosen after checking HF: its config
  sha256 `e23c5d98…` matches fangkemi's `docs/weights.md` receipt. NVIDIA's later HEAD `da920bb0` only changes
  `config.json` and `hf_quant_config.json` (MTP layer 45 ignore-list fix, HF discussion #11; not needed with DFlash2);
  all 33 shards are identical. The pinned drafter `incoai/GLM-5.3-Flash-DFlash2` @ `bf582e4e` is already on all nodes.
- **17:00 HF token stored** at `~/.cache/huggingface/token` (mode 600, sparkmain only, not in any script or log).
- **17:10 download queue (sparkmain only, detached, after the nvidia download):** `download-queue.sh` → `logs/download-queue.log`:
  `RedHatAI/GLM-5.3-Flash-NVFP4` @ `18d55bfd` (198 GB; alexellis measured +16 % prefill, code 75.2 on a 4× ring; drops
  into `glm-tp4.sh`) and `Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold` @ `76c0b517` (176 GB; TensorFold, 95.2 tok/s
  reported on 4×; the `…-EXL3-TR3-4bpw` repo named by `~/glm53-tensorfold` no longer exists, and this is its
  published mirror). Skipped: autotrust E224 (B200-validated only, same bytes per token), FP8 builds (slower), RadixArk and
  local-inference-lab (no Spark data). Total ~579 GB on sparkmain's 1.2 TB, so no deletions are needed for the downloads.
- **17:15 worker space cleared (user: "clear space as needed"):** removed the Qwen3.8-Flash-Next HF caches that sparkmain holds
  byte-identical copies of (same revision, file count, bytes): spark1 RadixArk (135 GB), spark2 RadixArk + local-inference-lab
  (241 GB), spark4 `~/offload/spark1-hf-hub` (106 GB, today's offload). Free now: spark1 233 GB, spark2 346 GB, spark4 289 GB.
  The old Qwen TP2/TP3 recipes need these caches re-copied from sparkmain (`~/.cache/huggingface/hub/models--…`) before reuse.
- **17:25 LVKP swap prepared:** fangkemi/knapcio repo @ `3b29b25` cloned to `research/GLM-5.3-Flash-4x-DGX-Spark-TP4`, site
  config `.env.switchless` (ring order, LAN bootstrap, our 4-HCA NCCL pinned by sha256, `10.100.160.0/21`, `/opt/glm53`
  paths, KV 12 GiB/rank instead of the profile's 24, :8100, model `glm-5.3-flash`). The dry run rendered cleanly.
  `lvkp-pipeline.sh` and `lvkp-watchdog.sh` start automatically once the nvidia download completes. Recovery steps
  are in the cluster notes ("In flight 2026-10-11 evening").
- **17:08–17:52 LVKP pipeline ran clean, first try.** GLM down 17:08 → images (40 s) → conversion (1 min; both config hashes
  matched knapcio's accepted build) → fabric copy 197 GB per worker (18 min) → launch 17:28 → ready 17:38 (510 s, cold
  caches) → gate 4/4 → bench x2, real-text, qeval 72/75. **LVKP is serving on :8100** (`glm53-switchless-r0..3`). The
  watchdog exited without acting. Results: `RESULTS.md` § LVKP. Downtime: 17:08–17:38.
- The previous build stays on disk (`~/glm53-flash-nvfp4`, `glm-tp4.sh`) for rollback. New on every node: `/opt/glm53/{src,overlay,models}`
  (197 GB on workers). sparkmain also has `~/models/{nvidia,RedHatAI}/…` (191 + 185 GB) and the EXL3 download in progress.
- **18:30 ring-RoCEnante test started (user: "merge in, then test"):** knapcio PR #4 (`3f7173f`, macoto-liu) merged locally on
  branch `sparkmain-ring` (`6bfa3a8`, no conflicts; CPU suite identical before/after, 15/15 env-dependent fails unchanged;
  switchless tests 9/9). `.env.ring`: `SWITCHLESS_ROCE_RING=1`, peer maps from `~/dsv41/ring-mesh/env.txt`, **caps 80 KiB**
  (our mesh's hairpin queue is 1024, not the PR's 8192/256 KiB), **KV 18 GiB/rank**, image `glm53-roce:v12-ring-sparkmain`,
  containers `glm53-ring-r0..3`, overlay `/opt/glm53/overlay-ring`, source `/opt/glm53/src-ring`. The mesh was already up
  (DSv4.1 markers and hardware tc rules on all 4 nodes); no fabric change. `ring-pipeline.sh`: stops LVKP (containers
  **preserved**), builds the image, runs the 4-rank ring smoke test, boots, checks `GLM_ROCE_READY` 4/4, then gate, bench x2,
  real-text and qeval x2. It keeps the ring build only if c1 beats LVKP's 114.6 and qeval stays ≥70 twice; otherwise
  `docker start` brings LVKP r3→r0 back. Guard: `ring-watchdog.sh` (3 h). Progress: `logs/ring/STATUS`.
  Also: sparkmain's `known_hosts` gained its own LAN address (`192.168.1.70`, needed by the smoke test).
- **19:00 ring test attempt 1 aborted by my launch bug (no ring code ran):** `setsid nohup … & P=$!` gave the watchdog setsid's
  short-lived parent PID, so it judged the pipeline dead 1 s in and began restoring LVKP while the pipeline was still
  stopping it. I killed the pipeline mid-`start.sh stop`, which left r0/r1 stopped and r2/r3 running. 19:11: all four
  LVKP containers stopped, GPUs verified idle, then `docker start` r3→r0. Fix: the pipeline now starts its own
  watchdog with `$$`. Logs: `logs/ring/` (attempt 1).
- **19:00–19:30 incident: accidental unplug, spark2 hard reset, LAN carrier drops (merged record from both Claude sessions).**
  The user unplugged a Spark by accident. All nodes logged `enP7s7` carrier drops at 19:00:56 (17 s), 19:01:58 (14 s),
  19:15:30 (14 s) and 19:23:39 (54 s). spark2 hard-reset: its previous boot ends at 19:15:14 with no shutdown, panic or OOM
  entry, and it booted again at 19:17:09. That wiped spark2's runtime fabric and mesh; session sparkmain-e1 re-ran
  `fabric-ring-up` (8/8 links, 16/16 GID3) and `dsv41-ring-up` (markers 2/2 everywhere) at 19:26–19:28.
  Two Claude sessions were driving the ring test at once. The source sync failed during the 19:15 drop
  (`logs/ring-attempt2-spark2-reset/`); a 19:30 relaunch never got past preflight (`logs/ring-attempt2-landrop/`).
  Both sessions stopped and started `glm53-switchless-r*` around 19:26–19:30. **LVKP serving again at 19:30:05** (checked
  again 19:31:15). Downtime about 19:14–19:30. No ring (PR #4) code has run. Reboot evidence: `logs/spark2-reboot/`.
- **Lessons:** TP ranks bootstrap and heartbeat over the LAN (TCPStore on 192.168.1.70:29669), so a ~1 min LAN outage can kill
  a serving engine although model traffic is on the RoCE ring. A node reboot wipes its runtime fabric and mesh: run
  `fabric-ring-up` and `dsv41-ring-up` before any engine. `ring-pipeline.sh` now refuses to start after a LAN drop in the
  last 20 min. Only one session may drive engines at a time: this session stopped its auto-starter
  (`ring-start-when-lan-stable.sh`, never launched) and holds all engine, fabric and ring actions until the user picks an owner.
