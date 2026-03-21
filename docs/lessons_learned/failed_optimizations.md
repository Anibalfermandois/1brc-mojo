# 1BRC Mojo — Failed Optimizations

This document records optimization attempts that did not yield the expected results. Documenting these prevents re-implementation and provides context for the current implementation.

## 32-Byte SIMD Unroll
- **Idea:** process 32 bytes per iteration.
- **Result:** ~5% regression in **Engine Throughput**.
- **Reason:** Building two 16-bit masks was more expensive than the loop overhead savings for 20-byte average rows.

## Batched 16-bit Hash Key Loads
- **Idea:** Use `UInt16` loads for hash key pieces.
- **Result:** ~4% regression.
- **Reason:** Two `ldrb` (byte) instructions are cheaper on ARM64 than one `ldrh` plus shifts.

## Compact StationStats (Int16/Int32 fields)
- **Idea:** Shrink stats to 16 bytes for cache density.
- **Result:** ~3% regression.
- **Reason:** The instruction overhead of widening/truncating types in the hot path exceeded the negligible cache benefits.

## Software Prefetch (`llvm.prefetch`)
- **Idea:** Manual L1 prefetching.
- **Result:** ~3% regression on warm cache.
- **Reason:** Hardware prefetcher is more efficient; manual hints were counter-productive.

## Integer Has-Zero-Byte Trick (No SIMD)
- **Idea:** Pure GPR (integer) register scan.
- **Result:** ~7% regression.
- **Reason:** 8-byte window size is 2× smaller than NEON's throughput.

## Explicit `comptime` for Loop Invariants
- **Result:** Neutral. Kept for hygiene.

## Removing the `reduce_or()` Guard
- **Result:** Neutral. SIMD reduction is inexpensive compared to the branch predictor savings.

## Semicolon "Has-Zero-Byte" Trick
- **Idea:** Use bitwise arithmetic (`(diff - 0x01...) & ~diff & 0x80...`) to find the semicolon index in a 64-bit word.
- **Result:** ~15% regression in **Engine Throughput**.
- **Reason:** On Apple Silicon (ARM64), the 3-4 instruction overhead of the bitwise trick is more expensive than the simple branchless math used in the baseline.

## Vectorized Parsing & Software Pipelining
- **Idea:** Split discovery and parsing into two stages (Stage 1: Batch Discovery → Stage 2: Vectorized Dispatch) to enable software pipelining/prefetching.
- **Results:** 
    - **Stage 2 Dispatch (Vertical SIMD):** ~43% regression (877ms vs 506ms).
    - **Single-Stage Prefetch:** ~18% regression (595ms).
    - **Multi-Stage Prefetch (Data + Bucket):** ~28% regression (649ms).
    - **Vectorized Hash (SIMD Gathers):** ~220% regression (1636ms - 2016ms).
- **Reason:** The overhead of batch buffer management and the extreme penalty of SIMD gathers far outweigh the theoretical benefits of hiding latency.
- **Full Report:** See [Vectorized Parsing Investigation (docs/vectorized_parsing_report.md)](../vectorized_parsing_report.md).

## The "mmap" Performance Cliff
- **Observation:** Benchmarking 100M rows (1.3GB) showed ~714M rows/s, while 600M rows (8.2GB) initially plummeted to ~85M rows/s.
- **Cause:** On a machine with 4.8GB RAM, `mmap` triggered severe page-cache trashing once the file size exceeded physical memory.
- **Resolution:** Lowered the `STREAMING_THRESHOLD` to 4GB. Using explicit `pread` with `F_NOCACHE` recovered the performance to ~326M rows/s (3.8x gain).
- **Lesson:** On macOS, explicit streaming is mandatory as soon as the dataset exceeds half of the available physical RAM.
