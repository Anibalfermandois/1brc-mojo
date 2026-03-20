# 1BRC Mojo — Architecture & Optimizations

This document outlines the technical architecture and the specific optimizations that enable the Mojo implementation to process 1 billion rows at extreme speeds.

## Executive Summary

The project achieves high throughput by combining Mojo's low-level systems capabilities (SIMD, pointers, metaprogramming) with a specialized architecture designed for the 1BRC dataset.

### Core Metrics (MacBook Air M2)
- **Peak Engine Throughput:** ~714 M rows/s (100M dataset)
- **RAM-Speed Throughput:** ~545 M rows/s (300M dataset)
- **Disk-Bound Throughput:** ~60 M rows/s (600M+ dataset)

For detailed results, see [Benchmarks](benchmarks.md) and [Performance Log](performance_log.md).

---

## Technical Modular Documentation

### 1. Primary Architecture
- **[Hash Table Design](optimizations/hash_table.md)**: Perfect hashing (O(1)), AoS for cache locality, and zero-allocation updates.
- **[I/O & Parallelism](optimizations/io_and_parallelism.md)**: Memory-mapped I/O with `madvise` strategies and linear scaling via `std.algorithm.parallelize`.

### 2. Hot Path Optimizations
- **[Hot Path Optimizations](optimizations/hot_path.md)**: hardware-accelerated SIMD scanning and branchless temperature parsing.

### 3. Language Features & Lifecycle
- **Metaprogramming**: Specialized machine code generation using `comptime`.
- **Memory Management**: Direct `UnsafePointer` indexing in the hot path, safe `ref` bindings in the merge path.
- **Modern Mojo Syntax**: Utilizing latest nightly features (`def`, `ref`, `comptime`).

### 4. Hardware Portability & Scaling
- Dynamic core allocation and universal SIMD width (128-bit) for ARM NEON support.
- Automatic paging strategy based on hardware RAM limits.

---

## Appendix: Lessons Learned

- **[Failed Optimizations](lessons_learned/failed_optimizations.md)**: Records of attempts that regressed performance (e.g., 32-byte unrolling, software prefetching).
- **[GPU Investigation](lessons_learned/gpu_investigation.md)**: Analysis of why CPU outperforms GPU for this specific memory-bound task.
