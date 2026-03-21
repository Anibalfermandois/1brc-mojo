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
