# Resident-data GPU newline scan: cold staging run

- Input: 1,379,614,933 bytes, 99,999,387 newlines
- Correctness: exact CPU/GPU count match before and after timing
- CPU: 8 threads, production 16-byte SIMD/SWAR mask
- GPU: Apple M3, 256 blocks x 256 threads
- Order: five CPU-GPU-GPU-CPU pairs under normal concurrent machine use
- Input staging: 2,077.689 ms immediately after dataset materialization

| Path | Median | MAD | IQR | Throughput |
|---|---:|---:|---:|---:|
| CPU SIMD scan | 61.386 ms | 0.304 ms | 0.617 ms | 22.47 GB/s |
| GPU kernel | 22.620 ms | 0.617 ms | 1.035 ms | 60.99 GB/s |

The occupied GPU kernel is 2.71x as fast as the parallel CPU scanner on
resident data. The staging measurement includes cold file faults and is not an
estimate of warm transfer cost.
