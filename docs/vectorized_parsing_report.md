# Report: Vectorized Parsing & Software Pipelining (Investigation)

**Status:** FAILED / NOT PROFITABLE
**Date:** 2026-03-20
**Target Hardware:** Apple M2 (16GB RAM)
**Mojo Version:** 0.26.3.0 nightly

## Objective
To investigate if a "Stage 1 / Stage 2" split (Structural Scan → Vectorized Dispatch) could outperform the baseline "Immediate Dispatch" model by utilizing SIMD gathers for hashing and software pipelining (prefetching) to hide memory latency.

## Architecture Variations Tested

### 1. Vectorized (Immediate)
- **Concept:** Use 64-byte SIMD blocks for boundary discovery, then parse row immediately.
- **Result:** ~510ms (300m dataset).
- **Finding:** The overhead of the 64-byte loop structure compared to the 16-byte loop (baseline) slightly reduced throughput.

### 2. Stashed "Vertical SIMD"
- **Concept:** Batch 16 boundaries, then use vertical SIMD (Splat-and-Select) for temperature parsing.
- **Result:** ~877ms (300m dataset).
- **Finding:** Gathering data into SIMD registers for such a theoretically thin operation (3 digits + sign) is more expensive than the scalar math.

### 3. Pipelined (Prefetch)
- **Concept:** Batch 16 boundaries, compute hashes, then issue prefetches for the hash map buckets before updating.
- **Result:** ~595ms (300m dataset).
- **Finding:** Prefetching for the hash map did not yield a net gain, likely because the 413-entry map and its hot access patterns are already well-handled by the hardware prefetcher.

### 4. Vectorized Hash (Gather)
- **Concept:** Use the `gather` intrinsic to extract bits for 16 station name hashes simultaneously.
- **Result:** **~1979ms** (300m dataset).
- **Finding:** The `gather` intrinsic on this architecture (ARM64) is extremely slow when locations are independent, likely decaying into serialized loads or incurring significant penalties.

### 5. Multi-Stage Pipelined
- **Concept:** 3-phase batching: Prefetch Name Data → Prefetch Map Buckets → Final Update.
- **Result:** ~649ms (300m dataset).
- **Finding:** Even with explicit staging to hide both name-load and hash-map latency, the management overhead of the batch buffer was too high.

## Performance Comparison (300m dataset)

| Implementation | Time (ms) | Throughput (M rows/s) |
| :--- | :--- | :--- |
| **Baseline (Immediate Dispatch)** | **506** | **592** |
| Pipelined (Single-Stage) | 595 | 504 |
| Multi-Stage Pipelined | 649 | 462 |
| Vectorized (Immediate) | 510 | 588 |

## Conclusion
The **Immediate Dispatch** baseline remains superior for 1BRC because:
1.  **Temporal Locality**: Data is parsed immediately after being scanned by SIMD, ensuring it is hot in L1 cache.
2.  **Instruction Density**: Temperature parsing is too simple to justify the complexity of SIMD gathering or software pipelining.
3.  **Low Arithmetic Intensity**: The task is entirely bound by the speed of scanning and hash-map updates; any architecture that adds "management logic" between those two points is likely to regress.

*Refer to `docs/architecture.md` for the current production logic.*
