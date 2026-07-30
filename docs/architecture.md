# 1BRC Mojo — Architecture & Optimizations

This document outlines the technical architecture and the optimizations used to
process the 1BRC datasets.

## Executive Summary

The project combines Mojo SIMD, pointers, metaprogramming, perfect hashing, and
thread-local aggregation in a specialized 1BRC parser.

### Validated Metrics (2026-07-30, Normal Concurrent Use)

- **100M lazy mmap:** 161.611 ms, 162.727 ms, and 165.741 ms wall medians.
- **300M streaming:** 1.248 s wall median; 245.57 M rows/s parse throughput.
- **600M streaming:** 2.480 s wall median; 244.58 M rows/s parse throughput.
- **1B streaming:** 4.126 s wall median; 244.01 M rows/s parse throughput.

For detailed results, see [Benchmarks](benchmarks.md) and [Performance Log](performance_log.md).

---

## Technical Modular Documentation

### 1. Primary Architecture
- **[Hash Table Design](optimizations/hash_table.md)**: Perfect hashing (O(1)), AoS for cache locality, and zero-allocation updates.
- **[I/O & Parallelism](optimizations/io_and_parallelism.md)**: Hybrid I/O model (demand-paged mmap below 2 GiB; bounded `pread` streaming at 2 GiB and above).

### 2. Hot Path Optimizations
- **[Hot Path Optimizations](optimizations/hot_path.md)**: hardware-accelerated SIMD scanning and branchless temperature parsing.

### 3. Language Features & Lifecycle
- **Metaprogramming**: Specialized machine code generation using `comptime`.
- **Memory Management**: Direct `UnsafePointer` indexing in the hot path, safe `ref` bindings in the merge path.
- **Mojo Toolchain**: Pinned by `pixi.lock`; benchmark metadata records the exact compiler build.

### 4. Hardware Portability & Scaling
- Dynamic core allocation and universal SIMD width (128-bit) for ARM NEON support.
- File-size-based selection between mmap and bounded streaming.

---

## Appendix: Lessons Learned

- **[Failed Optimizations](lessons_learned/failed_optimizations.md)**: Records of attempts that regressed performance (e.g., 32-byte unrolling, software prefetching).
- **[GPU Investigation](lessons_learned/gpu_investigation.md)**: Analysis of why CPU outperforms GPU for this specific memory-bound task.
