| op | np | rails | latency at smallest size, out-of-place (µs) | latency at 64 KB (µs) | peak busbw (GB/s) |
|---|---|---|---|---|---|
| all_reduce | 2 | rail1 | 29.5 (@8 B) | 73.2 | 13.05 (104 Gb/s) |
| all_reduce | 2 | both | 39.3 (@8 B) | 65.7 | 24.08 (193 Gb/s) |
| all_reduce | 3 | rail1 | FAILED | FAILED | FAILED (see Anomalies A1) |
| all_reduce | 3 | both | FAILED | FAILED | FAILED (see Anomalies A1) |
| all_reduce | 4 | rail1 | FAILED | FAILED | FAILED (see Anomalies A1) |
| all_reduce | 4 | both | FAILED | FAILED | FAILED (see Anomalies A1) |
| all_gather | 2 | rail1 | 22.6 (@32 B) | 43.9 | 12.96 (104 Gb/s) |
| all_gather | 2 | both | 22.1 (@32 B) | 49.4 | 23.81 (190 Gb/s) |
| all_gather | 3 | rail1 | FAILED | FAILED | FAILED (see Anomalies A1) |
| all_gather | 3 | both | FAILED | FAILED | FAILED (see Anomalies A1) |
| all_gather | 4 | rail1 | FAILED | FAILED | FAILED (see Anomalies A1) |
| all_gather | 4 | both | FAILED | FAILED | FAILED (see Anomalies A1) |
| reduce_scatter | 2 | rail1 | 24.7 (@32 B) | 44.5 | 12.97 (104 Gb/s) |
| reduce_scatter | 2 | both | 21.5 (@32 B) | 47.4 | 23.52 (188 Gb/s) |
| reduce_scatter | 3 | rail1 | FAILED | FAILED | FAILED (see Anomalies A1) |
| reduce_scatter | 3 | both | FAILED | FAILED | FAILED (see Anomalies A1) |
| reduce_scatter | 4 | rail1 | FAILED | FAILED | FAILED (see Anomalies A1) |
| reduce_scatter | 4 | both | FAILED | FAILED | FAILED (see Anomalies A1) |
| alltoall | 2 | rail1 | 27.4 (@32 B) | 29.8 | 12.66 (101 Gb/s) |
| alltoall | 2 | both | 27.4 (@32 B) | 39.0 | 22.99 (184 Gb/s) |
| alltoall | 3 | rail1 | FAILED | FAILED | FAILED (see Anomalies A1) |
| alltoall | 3 | both | FAILED | FAILED | FAILED (see Anomalies A1) |
| alltoall | 4 | rail1 | FAILED | FAILED | FAILED (see Anomalies A1) |
| alltoall | 4 | both | FAILED | FAILED | FAILED (see Anomalies A1) |

| pair (np=2) | rails | all_reduce 8 B (µs) | 64 KB (µs) | peak busbw (GB/s) |
|---|---|---|---|---|
| sparkmain+spark1 | rail1 | 29.5 | 73.2 | 13.05 |
| sparkmain+spark1 | both | 39.3 | 65.7 | 24.08 |
| spark1+spark2 | rail1 | 25.6 | 64.9 | 12.91 |
| spark1+spark2 | both | 36.7 | 70.0 | 24.00 |
| spark2+spark4 | rail1 | 25.2 | 63.9 | 13.31 |
| spark2+spark4 | both | 33.6 | 75.4 | 23.94 |
| spark4+sparkmain | rail1 | 99.5 | 65.4 | 13.50 |
| spark4+sparkmain | both | 35.0 | 71.3 | 24.03 |