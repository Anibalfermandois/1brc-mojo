# Resident-data GPU newline scan: warm repeat

- Input: 1,379,614,933 bytes, 99,999,387 newlines
- Correctness: exact CPU/GPU count match before and after timing
- CPU: 8 threads, production 16-byte SIMD/SWAR mask
- GPU: Apple M3, 256 blocks x 256 threads
- Order: five CPU-GPU-GPU-CPU pairs under normal concurrent machine use
- Warm input staging: 245.106 ms

| Path | Median | MAD | IQR | Throughput |
|---|---:|---:|---:|---:|
| CPU SIMD scan | 62.357 ms | 0.938 ms | 2.011 ms | 22.12 GB/s |
| GPU kernel | 23.685 ms | 1.551 ms | 3.313 ms | 58.25 GB/s |

The warm repeat confirms a 2.63x kernel-only GPU advantage despite higher
ordinary-use dispersion. Staging plus the median kernel takes about 268.8 ms,
so the copied-buffer path is not end-to-end competitive.
