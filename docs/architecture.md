# 1BRC Mojo — Architecture & Optimizations

This document outlines the technical architecture and the specific optimizations that enable the Mojo implementation to process 1 billion rows at extreme speeds.

## Latest Benchmark (2026-03-17 — Mojo 0.26.3.0 nightly, osx-arm64)

**File:** `measurements_600m.txt` (7.9 GB, 600M rows) — RAM-constrained (~4.7 GB free)

| Metric | min | median | avg | max | noise |
|---|---|---|---|---|---|
| **System Wall-Clock** | 9795ms | 10070ms | 10227ms | 11034ms | ±12% |

- **Baseline** (`600m-11000ms` commit): ~11000ms median
- **Current Performance**: ~10070ms median (System Total)
- **Bottleneck Analysis**: On this 16 GB machine (with ~8 GB free), files ≥ 8 GB exceed the OS physical RAM cache. Performance transitions from CPU-bound (RAM speed) to I/O-bound (SSD bandwidth).

## Table of Contents

- [0. Development Environment & Benchmarking](#0-development-environment--benchmarking)
- [1. Primary Architecture](#1-primary-architecture)
    - [A. Hash Table Design](#a-hash-table-design)
    - [B. I/O Strategy (mmap)](#b-io-strategy-mmap)
    - [C. Parallelization Pipeline](#c-parallelization-pipeline)
- [2. Hot Path Optimizations](#2-hot-path-optimizations)
    - [A. SIMD Row Scanning](#a-simd-row-scanning)
    - [B. Branchless Temperature Parsing](#b-branchless-temperature-parsing)
- [3. Language Features & Lifecycle](#3-language-features--lifecycle)
    - [A. Metaprogramming & Specialization](#a-metaprogramming--specialization)
    - [B. Memory Management & Lifecycle](#b-memory-management--lifecycle)
    - [C. Modern Mojo Syntax](#c-modern-mojo-syntax)
- [4. Hardware Portability & Scaling](#4-hardware-portability--scaling)
- [Appendix: Lessons Learned](#appendix-lessons-learned)
    - [A. Failed Optimizations](#a-failed-optimizations)
    - [B. GPU Investigation (Metal)](#b-gpu-investigation-metal)

---

## 0. Development Environment & Benchmarking

### Performance Metric Definitions
The `entrypoints/bench.sh` tool now explicitly reports two primary metrics:

1.  **System Wall-Clock (Total Duration)**: The end-to-end time measured by the shell. It includes process startup, memory-mapping (`mmap`), page-cache warming, the parallel parse, final result merging, and shell overhead.
2.  **Mojo Internal Parse Time (Engine Throughput)**: The duration of the specialized `parallelize` parse stage alone, measured internally by Mojo using `perf_counter_ns`. This is the "pure" throughput of the CPU processing RAM-cached data.

### Environment Setup (pixi)

The project uses [pixi](https://pixi.sh) for reproducible environment management.

```bash
pixi install        # create/update the environment
pixi run build      # compile src/perf.mojo → bin/perf_bin with -O3
pixi run bench      # warm-cache benchmark (default: measurements_300m.txt, 5 runs)
pixi run analyze    # deep metrics: collisions, distribution, and internal timing
```

### Profiling & Analysis

- **Deep Analysis:** `entrypoints/analyze.sh` (or `pixi run analyze`) tracks hash collisions and deep parser metrics with minimal overhead.

**Standardized Benchmark Results (Warm cache, MacBook Air M2):**

| Dataset | File size | Wall-Clock (Total) | Mojo Parse (Engine) | Engine Throughput |
|---|---|---|---|---|
| **100m** | 1.3 GB | ~190ms | ~140ms | **714.28 M rows/s** |
| **300m** | 3.9 GB | ~720ms | ~550ms | **545.45 M rows/s** |
| **600m** | 7.7 GB | ~10070ms | N/A | **60 M rows/s** (SSD Bound) |

---

## 1. Primary Architecture

### A. Hash Table Design (Deep Dive)
The hash table is the most critical component, as every row results in a lookup and an update.

#### A.1 Perfect Hashing (O(1) Guaranteed)
Instead of a general-purpose hash map, we use a **Perfect Hash Function** specialized for the 413 weather stations. This eliminates collisions entirely (Zero Probes) and enables the extreme **Engine Peak** throughput.

#### A.2 Array of Structures (AoS) for Cache Locality
We consolidated all per-station data into a single `MapEntry` struct (48 bytes). When the CPU fetches a station's stats, the name pointer and length are pulled into the **same cache line**.

#### A.3 Zero-Allocation Strategy
The hash table performs **zero heap allocations** during the hot loop. The table is pre-allocated on the heap using `UnsafePointer.alloc`.

#### A.4 Integer Accumulator
Temperatures are parsed as integers (e.g., `12.3` becomes `123`), keeping the hot path purely integer-based.

### B. I/O Strategy (mmap)
A `madvise` strategy is chosen based on file size:

| File size | Strategy | Reason |
|---|---|---|
| < 8 GB | `MADV_WILLNEED` | Pre-loads into RAM. Engine Throughput is CPU-bound. |
| ≥ 8 GB | `MADV_SEQUENTIAL` | Streams from disk. Engine Throughput is I/O-bound. |

**Key Insight:** For the 3.9 GB file, `MADV_WILLNEED` adds ~500ms–700ms to the "System Total" but allows the "Engine Peak" to reach its full potential.

### C. Parallelization Pipeline
Data is processed using `std.algorithm.parallelize`, scaling linearly with `num_logical_cores()`. Thread-local storage eliminates contention.

---

## 2. Hot Path Optimizations

### A. SIMD Row Scanning (with `std.bit`)
The inner loop of `parse_chunk` uses 16-byte SIMD windows and the `count_trailing_zeros` hardware-accelerated function (from `std.bit`) to locate newlines in 1 cycle. This replaced the raw `llvm.cttz.i16` intrinsic, maintaining the high **Engine Peak** performance. (maybe noice)

### B. Branchless Temperature Parsing (8-Byte Load)
Once a newline is found, the parser performs a single unaligned 8-byte load backwards. Bitwise arithmetic replaces conditionals for handling the sign and decimal point, keeping the instruction pipeline full.

---

## 3. Language Features & Lifecycle

### A. Metaprogramming & Specialization
Attributes like hash table `CAPACITY` are treated as `comptime` constants, allowing the compiler to generate zero-overhead specialized machine code.

### B. Memory Management & Lifecycle

#### B.1 Direct Indexing in Hot Path
To maintain throughput, we use direct `UnsafePointer` indexing. In tests, using high-level reference features in the 300M-row hot path caused a performance regression from ~476 M rows/s down to ~50 M rows/s.

#### B.2 Safe Reference Usage (Merge Path)
Reading values from threads uses `read` arguments and `ref` bindings. These have zero overhead in the non-critical merge path while providing memory safety.

### C. Modern Mojo Syntax (nightly 0.26+)
Targets latest nightly conventions (e.g., `comptime` instead of `alias`, `def` over `fn`).

---

## 4. Hardware Portability & Scaling

- **Dynamic Core Allocation**: Scales with `num_logical_cores()`.
- **Universal SIMD Width**: Uses `width = 16` (128-bit) for universal ARM NEON support.
- **Large-File Support**: Automatically switches to `MADV_DONTNEED` paging to prevent crashes on RAM-limited hardware.

---

## Appendix: Lessons Learned

### A. Failed Optimizations
Documented to prevent re-implementation.

#### A.1 32-Byte SIMD Unroll
- **Idea:** process 32 bytes per iteration.
- **Result:** ~5% regression in **Engine Throughput**.
- **Reason:** Building two 16-bit masks was more expensive than the loop overhead savings for 20-byte average rows.

#### A.2 Batched 16-bit Hash Key Loads
- **Idea:** Use `UInt16` loads for hash key pieces.
- **Result:** ~4% regression.
- **Reason:** Two `ldrb` (byte) instructions are cheaper on ARM64 than one `ldrh` plus shifts.

#### A.3 Compact StationStats (Int16/Int32 fields)
- **Idea:** Shrink stats to 16 bytes for cache density.
- **Result:** ~3% regression.
- **Reason:** The instruction overhead of widening/truncating types in the hot path exceeded the negligible cache benefits.

#### A.4 Software Prefetch (`llvm.prefetch`)
- **Idea:** Manual L1 prefetching.
- **Result:** ~3% regression on warm cache.
- **Reason:** Hardware prefetcher is more efficient; manual hints were counter-productive.

#### A.5 Integer Has-Zero-Byte Trick (No SIMD)
- **Idea:** Pure GPR (integer) register scan.
- **Result:** ~7% regression.
- **Reason:** 8-byte window size is 2× smaller than NEON's throughput.

#### A.6 Explicit `comptime` for Loop Invariants
- **Result:** Neutral. Kept for hygiene.

#### A.7 Removing the `reduce_or()` Guard
- **Result:** Neutral. SIMD reduction is inexpensive compared to the branch predictor savings.

#### A.8 Semicolon "Has-Zero-Byte" Trick
- **Idea:** Use bitwise arithmetic (`(diff - 0x01...) & ~diff & 0x80...`) to find the semicolon index in a 64-bit word.
- **Result:** ~15% regression in **Engine Throughput**.
- **Reason:** On Apple Silicon (ARM64), the 3-4 instruction overhead of the bitwise trick is more expensive than the simple branchless math used in the baseline.

### B. GPU Investigation (Metal)
Can Apple Silicon's unified memory allow a Metal GPU kernel to parse faster?
**Conclusion: No. GPU is 7.3× slower end-to-end.**

#### Key Bottlenecks:
- **Data Upload:** Metal requires copies (~8 GB traffic for 4 GB file). CPU `mmap` is zero-cost.
- **Memory Access:** 1BRC is a low arithmetic intensity task (1.5 FLOPs/byte). CPUs excel at these memory-bound scans; GPUs excel at high-intensity compute (1000+ FLOPs/byte).

#### Benchmark Results (300M rows, System Wall-Clock)
| Phase | CPU (`main.mojo`) | GPU (`gpu_main.mojo`) |
|---|---|---|
| Parallel parse | **486ms** | **4686ms** |
| Total | **~2467ms** | **~17939ms** |
