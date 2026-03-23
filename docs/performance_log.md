# 1BRC Mojo — Performance Log

This file tracks the performance of different optimizations over time. New results should be **appended** to the end of this document.

## Performance History

| Date | Commit/Version | Dataset | System Wall-Clock (median) | Engine Throughput (rows/s) | Notes |
|---|---|---|---|---|---|
| 2026-03-17 | `600m-11000ms` | 600M | 11000ms | - | Baseline for 600M |
| 2026-03-17 | Current | 600M | 10070ms | - | Current optimized state |
| 2026-03-17 | Current | 300M | 720ms | 545.45M | Standardized run |
| 2026-03-17 | Current | 100M | 190ms | 714.28M | Standardized run |
| 2026-03-20 | Post-Cleanup | 300M | 612ms | 666.67M | After removing experimental vectorized code |
| 2026-03-20 | Streaming I/O | 300M | 624ms | 652.17M | Explicit pread + Double-buffering |
| 2026-03-20 | Streaming I/O | 600M | 6993ms | 112.71M | Significant gain over mmap on MacOS (600M=7.8GB) |
| 2026-03-20 | Comptime Opt | 300M | 632ms | 638.30M | Added Likely and unlikely |
| 2026-03-20 | Aligned Streaming | 100M | 137ms | 729.92M | With 4MB blocks and F_NOCACHE |
| 2026-03-20 | Lookahead v2 | 600M | 7055ms | 85.05M | Sustainable streaming beyond 4.8GB RAM |
| 2026-03-20 | Gap Recovery | 600M | 1836ms | 326.73M | Threshold lowered to 4GB (3.8x gain over mmap) |
| 2026-03-21 | Ownership Opt | 300M | 413ms | 725.82M | Idiomatic ownership and `ref` in map merge |
| 2026-03-21 | No Signature | 600M | 1691ms | 354.82M | Removed signature check from hot path |
| 2026-03-21 | Perfect Hash | 600M | 1733ms | 354.82M | made table smaller |
| 2026-03-21 | No Signature | 600M | 1630ms | 354.82M | No signature + no computer ram pressure |
| 2026-03-22 | 2-Load Hash | 600M | 1583ms | 354.82M | 2-Load Hash |
| 2026-03-22 | 4x Unroll | 300M | 525ms | - | Unrolled SIMD loop |
| 2026-03-22 | Combined Mask | 300M | 424ms | - | Combined reduction checks in unrolled loop |
| 2026-03-22 | 32B MapEntry | 300M | 431ms | - | Reduced MapEntry from 48B to 32B (Min result) |
| 2026-03-22 | Branchless Update | 300M | 418ms | - | Branchless min/max + peeled newline loop (Min) |
| 2026-03-22 | Magic Movemask | 300M | 401ms | - | Record. Magic 64-bit Movemask + rbit/clz |
| 2026-03-22 | Refined Movemask | 300M | 396ms | - | **New Record**. 0x0F masking + likely() loops. |
| 2026-03-22 | Magic Movemask | 100M | 123ms | - | **Record**. |
| 2026-03-22 | Magic Movemask | 600M | 1.63s | - | **Record**. |
| 2026-03-22 | Magic Movemask | 1B | 4.36s | - | **Record**. (Previous best: 10.4s) |
| 2026-03-22 | Magic Movemask | 1B | 4.3604s | - | Updated Movemask with 0x0F masking + likely() loops. |
| 2026-03-23 | 32B MapEntry | 1B | 4223ms | 236.80M | **New Record**. 32-byte MapEntry optimization. |
