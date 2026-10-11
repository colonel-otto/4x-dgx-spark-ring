# GLM-5.3-Flash site recipe (sparkmain ring)

Third-party sources are cloned locally under `research/` and are **not** committed. Pins:

| what | source | pin |
|---|---|---|
| fabric + first GLM build | [alexellis/glm-5.3-flash-4x-dgx-spark-switchless](https://github.com/alexellis/glm-5.3-flash-4x-dgx-spark-switchless) | `e2d0839` |
| LVKP build (serving) | [fangkemi/GLM-5.3-Flash-4x-DGX-Spark-TP4](https://github.com/fangkemi/GLM-5.3-Flash-4x-DGX-Spark-TP4) (fork of knapcio) | `3b29b25` |
| ring RoCEnante (under test) | [knapcio PR #4](https://github.com/knapcio/GLM-5.3-Flash-4x-DGX-Spark-TP4/pull/4) (macoto-liu), merged locally on branch `sparkmain-ring` → `6bfa3a8` | `3f7173f` |
| weights | `nvidia/GLM-5.3-Flash-NVFP4` @ `09b04e5e` → lossless8 (config sha `f14dc13c…`), drafter `incoai/GLM-5.3-Flash-DFlash2` @ `bf582e4e` → FP8-block (`15bc8429…`) | |

`env.switchless` = the LVKP serving config (`ENV_FILE=.env.switchless` in the fangkemi checkout); `env.ring` = the
ring-RoCEnante test config (peer maps from our sparkring mesh plan, 80 KiB caps for hairpin queue 1024, KV 18 GiB).
Neither contains credentials. Driver scripts (`glm-tp4.sh`, `lvkp-pipeline.sh`, `ring-pipeline.sh`, watchdogs) are one
level up.
