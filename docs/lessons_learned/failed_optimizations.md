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
## Sub-8192 Hash Table Capacity
- **Idea:** Scale the perfect hash table capacity down from 16384/8192 to 4096 to increase cache density (using multiplier `3691286356690509567`).
- **Result:** ~2-6% regression (highly dependent on the specific multiplier).
- **Reason:** For this specific workload (413 active stations), the working set fits completely in L1 D-Cache regardless of the total table size. 413 active entries × 48 bytes = ~20 KB, well within the 128 KB L1D of Apple M2.
- **Analysis:** 
    1. **Red Herring:** Shrinking the table from 16384 to 4096 doesn't make the *hot set* any smaller; only the same 413 slots are eve.r accessed. 
    2. **Multiplier Quality:** Different multipliers distribute the stations to different physical addresses. A regression is more likely due to a multiplier accidentally creating L1 cache set conflicts between frequently co-accessed stations, rather than the capacity itself.
- **Lesson:** When the working set already fits in the fastest cache level, further shrinking the data structure provides no theoretical benefit and may introduce layout-dependent noise. Stick to the capacity and multiplier that yields the best stable benchmark (currently 16384 slots).

## Tight Loop Pipelining
- **Idea:** Pipeline the 64-byte `parse_chunk` loop by prefetching the *next* block of `c0..c3` SIMD vectors from memory *while* processing the newlines of the *current* block, aiming to overlap memory latency with parsing computation.
- **Result:** Neutral to slightly worse (~429ms vs 424ms baseline).
- **Reason:** Apple Silicon's Out-of-Order execution engine and hardware prefetcher are highly optimized for sequential, unrolled memory accesses. Eagerly issuing loads artificially pressured registers and instruction scheduling, disrupting the hardware's own pipelining without yielding any memory stall savings.
