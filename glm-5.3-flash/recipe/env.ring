# sparkmain ring site config, ring RoCEnante (knapcio PR #4 merged locally on branch sparkmain-ring), 2026-10-11.
#   ENV_FILE=.env.switchless ./start.sh serve|stop|status|logs
# Ring order = TP rank order: sparkmain(0) -> spark1(1) -> spark2(2) -> spark4(3). Bootstrap on the 1 GbE LAN.
HOSTS="local spark1 spark2 spark4"
SSH_OPTS="-o BatchMode=yes"
IPS="192.168.1.70 192.168.1.6 192.168.1.66 192.168.1.76"
FABRIC_IFACE=enP7s7
IB_HCA=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1
# Our qualified ondigo 4-HCA switchless build (2026-10-10 gate, 186 Gb/s; served GLM today), identical on all 4 nodes.
NCCL_HOST_DIR=/opt/nccl-switchless-4hca
SWITCHLESS_NCCL_SHA256=1c0dc70a00da7540be4c187921b19f4ffe7525e7b72a04fdc0b138c0d9ddfd1d
# Ring fabric 10.100.160-167.0/24, one /24 per logical link.
SWITCHLESS_ADDR_RANGE=10.100.160.0/21
SWITCHLESS_SUBNET_PREFIX_LEN=24
TRANSPORT=switchless
IMAGE=glm53-roce:v12-ring-sparkmain
# Identical absolute paths on every node (home dirs differ; rsync does not expand $HOME remotely). Same FS as / for hardlinks.
MODEL_DIR=/opt/glm53/models/glm-quant-mix/lossless8
DRAFT_DIR=/opt/glm53/models/incoai/GLM-5.3-Flash-DFlash2-fp8blk
CTN=glm53-ring
OVERLAY_REMOTE=/opt/glm53/overlay-ring
source profiles/current.env
# Site overrides after the profile:
KV_BYTES=19327352832           # 18 GiB/rank (user-approved 2026-10-11; 37 GB MemAvailable at 12 GiB)
HOST_BIND=0.0.0.0              # LAN/Tailscale clients, like the current :8100 endpoint
PORT=8100                      # the cluster's serving port
SERVED_NAME=glm-5.3-flash      # keep the model id clients already use
# Ring RoCEnante (PR #4). Mesh = the DSv4.1 sparkring mesh (~/dsv41/ring-mesh/env.txt), already up; peer maps from it.
SWITCHLESS_ROCE_RING=1
SWITCHLESS_ROCE_PEER_HCA_MAPS="1=0/2,2=0/3,3=1/3;0=1/3,2=0/2,3=0/3;0=1/2,1=1/3,3=0/2;0=0/2,1=1/2,2=1/3"
# Our mesh runs hairpin_queue_size 1024 (no devlink re-init) -> cap 80 KiB, not the PR's 256 KiB (queue 8192).
SWITCHLESS_ROCE_MAX_SIZE=81920
SWITCHLESS_ROCE_GATHER_MAX_SIZE=81920
