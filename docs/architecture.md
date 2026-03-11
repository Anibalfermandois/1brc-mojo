# 1BRC Mojo — Architecture & Optimizations

This document outlines the technical architecture and the specific optimizations that enable the Mojo implementation to process 1 billion rows at extreme speeds.

## 0. Benchmarking & Profiling

We use a custom `Profiler` (in `src/profiler.mojo`) to measure the performance of different pipeline stages.

- **Production timing:** Run `mojo run src/main.mojo <file>` to see the full output and profiler report.
- **Performance & Analysis:** Run `mojo run src/perf.mojo <file>` for throughput (benchmark mode).
- **Deep Analysis:** Run `mojo run src/perf.mojo <file> --analyze` for hash collision and parser metrics.

```bash
# Run benchmark
mojo run src/perf.mojo measurements_300m.txt

# Run deep analysis
mojo run src/perf.mojo measurements_300m.txt --analyze
```

## 1. Hash Table Architecture (Deep Dive)

The hash table is the most critical component, as every row results in a lookup and an update.

### A. Perfect Hashing (O(1) Guaranteed)
Instead of a general-purpose hash map, we use a **Perfect Hash Function** specialized for the 413 weather stations.
- **Mechanism:** We sample 5 specific bytes from the station name (first, second, middle, second-to-last, and last) and pack them into a `UInt64`.
- **Optimization:** This integer is multiplied by a magic constant and shifted to produce a unique index into a fixed-size table. This eliminates collisions entirely (Zero Probes) and avoids expensive byte-by-byte hashing.

### B. Array of Structures (AoS) for Cache Locality
We consolidated all per-station data into a single `MapEntry` struct.
- **Layout:**
  ```mojo
  struct MapEntry:
      var stats: StationStats # min, max, sum, count (32 bytes)
      var ptr: UnsafePointer[UInt8] # pointer to name in mmap (8 bytes)
      var length: Int # length of name (8 bytes)
  ```
- **Benefit:** Total size is 48 bytes. When the CPU fetches a station's stats, the name pointer and length are pulled into the **same cache line**. This reduces memory stalls and register pressure (tracking 1 base pointer instead of 4).

### C. Zero-Allocation Strategy
The hash table performs **zero heap allocations** during the hot loop.
- All station names are referenced via pointers directly into the memory-mapped file.
- The table is pre-allocated on the heap using `UnsafePointer.alloc` to prevent stack overflows and ensure a stable memory address for all threads.

### D. Integer Accumulator
Temperatures are parsed as integers (e.g., `12.3` becomes `123`).
- **Optimization:** We store `sum`, `min`, and `max` as integers. Floating-point division by 10.0 is deferred until the final result printing. This avoids `100M` float conversions and keeps the hot path purely integer-based.

---

## 2. I/O & Parallelization

### A. Memory-Mapped I/O (`mmap`)
The project utilizes the `MappedFile` (wrapping the system `mmap` call) to map the dataset directly into the process's virtual address space.
- **Optimization:** This avoids the "double buffering" cost of traditional `read()` calls, where data is copied from the kernel's page cache into a user-space buffer. Mojo's `UnsafePointer` interacts directly with the kernel's memory pages.

### B. Parallel Processing Pipeline
Data is processed using `std.algorithm.parallelize`, scaling linearly with `num_logical_cores()`.
- **Safe Chunk Boundaries:** To avoid splitting a station/temperature line across two threads, the main thread calculates "guess" boundaries and then "retreats" each thread's start position to the preceding newline character (`ASCII_LF`).
- **Thread-Local Storage:** Each thread maintains its own `PerfectStationMap`. This eliminates contention and locks. Once parsing is complete, these local maps are merged into a final result map in `O(N_threads * N_stations)` time.
- * performance vs effient cores: they have been seen to perform very similarly, so we can treat them same.
---

## 3. Parsing & Computation

### A. SIMD Row Scanning (with LLVM Intrinsics)
The inner loop of `parse_chunk` uses SIMD (Single Instruction, Multiple Data) to scan for newlines in 16-byte chunks.
- **Mechanism:** It loads a 16-byte window into a SIMD vector and compares it against a vector of newlines using `chunk.eq(nl_vec)`. The boolean mask is cast to a `UInt8` vector, multiplied by powers of 2, and reduced into a single 16-bit scalar integer bitmask.
- **Hardware Acceleration:** To avoid unrolling loops and branching when processing the bitmask, we directly invoke the LLVM backend intrinsic `llvm.cttz.i16`. This provides a 1-cycle hardware count of trailing zeros to instantly locate the exact offset of the next newline within the 16-byte window, skipping cleanly from newline to newline.

### B. Branchless Temperature Parsing (8-Byte Load)
Temperature parsing is done **backwards** from the calculated newline offset.
- **Mechanism:** Once the newline is found, the parser performs a single unaligned 8-byte load backwards from the newline using `(ptr + offset).bitcast[UInt64]().load()`.
- **Optimization:** Instead of loading individual character bytes sequentially, which forces multiple memory accesses, the 8-byte load pulls the entire temperature string and the trailing semicolon directly into a single CPU register. We extract the fraction, units, and structural bytes using bitwise shifts (e.g., `(chunk8 >> 56) & 0xFF`), completely eliminating per-byte loads and memory latency from the critical path.
- **Logic:** We use bitwise arithmetic to handle the optional sign and optional tens digit without conditionals. This keeps the CPU's pipeline full and avoids branch misprediction penalties.

---

## 4. Metaprogramming & Materialization

### A. Specialization via Parameters
`PerfectStationMap` is a parameterized struct.
- **Optimization:** Parameters like `CAPACITY` and `MULTIPLIER` are treated as compile-time constants. This allows the compiler to unroll loops, inline the hash function perfectly, and eliminate dead code (e.g., when `TRACK_METRICS` is False).

### B. Value Semantics & ImplicitlyCopyable
We use Mojo's `ImplicitlyCopyable` and `Movable` traits for the stats and entry structs.
- **Materialization:** This allows the compiler to "materialize" values directly into their final destination in memory or registers, significantly reducing the overhead of moving complex data types between functions and threads.

---

## 5. Memory Management & Lifecycle

### A. Direct Indexing in Hot Path
To maintain maximum throughput (~340 M rows/s), we use direct `UnsafePointer` indexing (`self.data[idx]`) in the `update_or_insert` hot loop.
- **Discovery:** Attempting to use `ref` bindings in the hot path resulted in a significant performance regression (down to ~50 M rows/s), likely due to the overhead of reference life-cycle management or disruptions to the compiler's loop optimizations.
- **Optimization:** Direct indexing allows the compiler to optimize register usage and pipelining without the overhead of tracking reference lifetimes within the tightest loop.

### B. Safe Reference Usage (Merge Path)
While avoided in the hot path, Mojo's advanced memory management provides benefits in the merge and formatting stages.
- **Read References:** In `update_from_stats`, we use the `read` convention (`read incoming: StationStats`). This ensures the 32-byte statistics struct is passed by reference, avoiding stack copies during the thread-merge phase.
- **Ref Bindings:** In `merge_from` and `print_sorted`, we use `ref` bindings to access map entries. Since these functions are not called per-row, the safety and readability benefits of `ref` outweigh any negligible overhead.

---

## 6. Hardware Portability & Scaling

The codebase is built specifically to seamlessly scale horizontally on larger machines (e.g., MacBook Pro M3 Max/M4 Max) without needing source code modifications:

### A. Dynamic Core Allocation
In `src/perf.mojo`, thread allocation is completely dynamic via `num_logical_cores()`. The chunk offsets are dynamically sliced, meaning a 12-core or 16-core CPU will automatically divide the file perfectly without hardcoded thread counts.

### B. Universal ARM NEON SIMD Width
In `src/parser.mojo`, we hardcode `comptime width = 16`. This matches the 128-bit NEON vector width that is universally identical across all Apple Silicon processors (M1 through M4). This guarantees optimal vectorization without any "out of bounds" hardware faults.

### C. Ahead-Of-Time (AOT) Host Targeting
When moving this code to a new computer, **you must re-run `build.sh` on the target machine**. The Mojo compiler uses the host architecture by default (similar to Clang's `-march=native`), baking in the exact L2/L3 cache line sizes, vector extensions, and pipeline definitions for that specific M-series chip. Do not copy the compiled `bin/perf_bin` between different computers.
