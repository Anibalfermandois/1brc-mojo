# GPU station indexing gate

- Input: 1,379,614,933 bytes, 99,999,387 rows
- Correctness: exact CPU/GPU match for row count, temperature sum, dense-ID
  sum, squared-ID sum, and zero invalid stations
- CPU: 8 threads, SIMD newline discovery and generated station perfect hash
- GPU: Apple M3, 256 blocks x 256 threads
- Order: five CPU-GPU-GPU-CPU pairs under normal concurrent machine use

The retained GPU kernel uses the fixed 413-station universe. The normalized
last eight bytes distinguish 411 stations directly. `Alice Springs` and
`Palm Springs` share a suffix and are separated by the ninth byte. A perfect
8,192-slot multiplicative hash feeds a 1.25 KiB occupancy-and-prefix structure
that converts occupied slots to dense `0..412` IDs.

| Series and path | Median | MAD | IQR |
|---|---:|---:|---:|
| Faster series, CPU station index | 135.773 ms | 1.490 ms | 2.981 ms |
| Faster series, GPU station index | 143.384 ms | 4.347 ms | 15.632 ms |
| Faster series, immediate GPU repeats | 139.139 ms | 0.033 ms | 0.131 ms |
| Final repeat, CPU station index | 145.157 ms | 6.860 ms | 14.261 ms |
| Final repeat, GPU station index | 172.717 ms | 2.620 ms | 5.087 ms |
| Post-change verification, CPU | 140.796 ms | — | — |
| Post-change verification, GPU | 163.695 ms | — | — |

Normal workstation activity is part of the measurement condition. The first
GPU sample after CPU work was consistently noisier; the immediate repeat was
stable near 139.1 ms. Even that favorable warm figure does not beat the CPU
index reference and is already near the full CPU parser's roughly 140 ms kernel
time. A later exact repeat under heavier concurrent activity degraded to
172.717 ms GPU median. The claim is therefore bounded to best-observed near
parity, not repeatable parity. A third post-change verification landed at
163.695 ms GPU versus 140.796 ms CPU. Workgroup aggregation fails its entry
gate across all three sessions.

## Rejected station-index variants

| GPU variant | Median | Result |
|---|---:|---|
| Scalar backward row recovery | 315.467 ms | Rejected |
| 16-byte backward SIMD recovery | 232.098 ms | Rejected |
| 256-byte shared masks with block barriers | 323.083 ms | Rejected |
| SIMD-group ballot plus fallback | 230.602 ms | Rejected |
| Eight-byte suffix with 32 KiB direct map | 232.169 ms | Rejected |
| Eight-byte suffix with 16 KiB direct map | 169.562 ms | Rejected |
| Eight-byte suffix with compact rank map | 143.384 ms | Retained research baseline |

The experiments isolate dense-ID lookup footprint as the dominant indexing
cost. Shrinking it from a 32 KiB direct table to the rank structure recovered
about 89 ms, but did not create enough headroom for aggregation.
