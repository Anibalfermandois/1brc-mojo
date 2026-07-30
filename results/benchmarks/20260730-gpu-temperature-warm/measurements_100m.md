# GPU temperature-only parser: warm repeat

- Input: 1,379,614,933 bytes
- Expected: 99,999,387 rows, fixed-point sum 17,828,649,656
- Correctness: exact CPU/GPU count and sum match before and after timing
- CPU: 8 threads, 16-byte SIMD/SWAR newline discovery
- GPU: Apple M3, 256 blocks x 256 threads
- Order: five CPU-GPU-GPU-CPU pairs under normal concurrent machine use

| Path | Median | MAD | IQR | Throughput |
|---|---:|---:|---:|---:|
| CPU temperature parser | 79.570 ms | 0.220 ms | 0.817 ms | 17.34 GB/s |
| GPU temperature kernel | 59.211 ms | 2.098 ms | 3.934 ms | 23.30 GB/s |

The warm repeat confirms a 1.34x GPU advantage. The next stage is station
indexing and dense workgroup aggregation; it has only about 20 ms of isolated
headroom over this CPU reference before the kernel advantage disappears.
