# Ring fallback (saved 2026-10-11 ~20:00 EDT, before moving to the MikroTik CRS504)

The switchless ring as it last served GLM-5.3 LVKP (c1 ~115 tok/s, c16 ~296). Everything here is runtime-only state
plus the scripts that recreate it.

- `<node>.txt`: live state per node — addresses, MTUs, routes (incl. the opposite-node /32s), GID index 3,
  sparkring mesh markers and tc hairpin rules, NFS.
- `fabric-ring-up.sh`, `dsv41-ring-up.sh`, `ring-mesh/`: copies of the scripts that rebuild it.
- `.env.switchless`: the GLM LVKP serving config used on the ring.

Restore the ring:
1. Stop whatever engine is serving.
2. Re-cable the ring: sparkmain-p0 to spark1, spark1 to spark2, spark2 to spark4, spark4-p1 to sparkmain. Edges:
   `sparkmain --(164/165)-- spark1 --(160/161)-- spark2 --(166/167)-- spark4 --(162/163)-- sparkmain`.
   Compare the result with the addresses in `<node>.txt`.
3. Undo any switch addressing on the fabric ports, then run `~/fabric-ring-up.sh` and `~/bin/dsv41-ring-up.sh` with
   the engine stopped.
4. Check: `ping -M do -s 8972` on every link; GID 3 = `RoCE v2`; 2 mesh markers running per node.
5. Start GLM: `cd /opt/glm53/src && ENV_FILE=.env.switchless bash start.sh serve`, or `docker start` the preserved
   containers r3, r2, r1, then r0.
