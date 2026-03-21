# Future Optimization Roadmap

Following the successful implementation of the high-performance macOS I/O path, these three options offer the most significant remaining performance gains:

## 1. Zero-Collision Perfect Hashing
**Goal**: Achieve O(1) hashmap access with zero probes (no branching on collisions).

- **Concept**: Use Mojo `comptime` to find a perfect hash salt/multiplier for the fixed set of 10,000 station names.
- **Implementation**:
    - During compilation, read the `stations.txt` or a representative dataset.
    - Bruteforce a small multiplier (e.g., `131`, `313`) and shift that results in zero collisions in the fixed-size array.
    - Specialize the `PerfectStationMap` with these constants.
- **Expected Gain**: ~3-5% reduction in overall wall-clock time by removing collision-handling branches.

## 2. Asynchronous "Lookahead" I/O [DONE]
**Goal**: Overlap disk latency with CPU parsing using true background threads.

- **Status**: Implemented refined double-buffered stream with block-prefetch logic.
- **Results**: Recovered 3.8x performance for datasets exceeding RAM (600M+).

## 3. Vectorized Hash Probing & Prefetching
**Goal**: Mitigate CPU stalls caused by random memory access in the hashmap.

- **Concept**: Separate the "Find Semicolon" step from the "Update Hashmap" step to allow for memory prefetching.
- **Implementation**:
    - **Step 1**: SIMD scan for semicolons/newlines and calculate hash indices for a batch of 8-16 rows.
    - **Step 2**: Issue `_mm_prefetch` for the calculated hash indices in the map.
    - **Step 3**: Actually perform the temperature parsing and map updates once the indices are (likely) in L1/L2 cache.
- **Expected Gain**: Significant reduction in "Loads Stalled" cycles, potentially increasing GB/s by 15-20%.

## Long-term Experiments
- **Metal Integration**: Using Apple Silicon's GPU to offload the initial structural scan.
- **Compressed Store**: Utilizing `compressed_store` intrinsics for even denser memory writes during the merge phase.
