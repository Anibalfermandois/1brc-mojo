# GPU temperature-only parser: first series

- Input: 1,379,614,933 bytes
- Expected: 99,999,387 rows, fixed-point sum 17,828,649,656
- Correctness: exact CPU/GPU count and sum match before and after timing
- CPU: 8 threads, 16-byte SIMD/SWAR newline discovery
- GPU: Apple M3, 256 blocks x 256 threads
- Order: five CPU-GPU-GPU-CPU pairs under normal concurrent machine use

| Path | Median | MAD | IQR | Throughput |
|---|---:|---:|---:|---:|
| CPU temperature parser | 79.495 ms | 0.127 ms | 0.207 ms | 17.35 GB/s |
| GPU temperature kernel | 61.286 ms | 2.994 ms | 6.267 ms | 22.51 GB/s |

The GPU is 1.30x as fast. Temperature parsing preserves an advantage but
consumes most of the scan-only kernel's 2.7x lead.
