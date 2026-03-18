# Optimization Proposals from Analysis Mode

Based on `pixi run mojo run src/perf.mojo measurements_300m.txt --analyze` (2026-03-18).

```
Throughput:   113.39 M rows/s  (1.45 GB/s)
Wall-clock:   4643ms  [I/O 43% | Parse 57%]
```

---

## 1. Thread Skew (45.77%)

**Data:**
```
Fastest thread:  873ms
Slowest thread: 1611ms
Thread skew:     45.77%
```

**Root cause:** Chunks are split by equal byte size, not equal row count. Threads that land
on long city names (max 26 bytes) do significantly more work than threads with short names.

**Proposal: Work stealing via atomic chunk counter**

Split the file into `num_threads × N` sub-chunks (N ≈ 8–16). Threads race for the next
available sub-chunk via an `Atomic.fetch_add`. Each thread still writes to its own
`maps_ptr[tid]` — no lock needed.

```mojo
comptime CHUNKS_PER_THREAD = 8
var next_chunk = Atomic[DType.int64](0)

@parameter
fn process_chunk[STREAMING: Bool](tid: Int):
    while True:
        var idx = Int(next_chunk.fetch_add(1))
        if idx >= num_sub_chunks: break
        parse_chunk(maps_ptr[tid], ptr + starts[idx], lens[idx], metrics)
```

**Expected gain:** parse stage drops from 1611ms (slowest) toward ~900ms (fastest).
Biggest impact on 100m benchmark where parse is the dominant cost.

---

## 2. I/O Preload Dominance (43% of wall-clock)

**Data:**
```
I/O Setup (mmap):   1997ms  (43%)
Parallel Parse:     2645ms  (57%)
Strategy:           MADV_WILLNEED (Preload)
Effective I/O:      1.45 GB/s
```

**Observation:** Nearly half the total wall-clock is spent preloading the file into RAM
before a single row is parsed. The parse stage can't start until `MADV_WILLNEED` returns.

**Proposal: Overlap I/O and parse (pipeline preload)**

Instead of preloading the whole file then parsing, feed chunks to threads as soon as their
pages are resident. Split the file into stripes, issue `madvise(MADV_WILLNEED)` on stripe N
while threads are parsing stripe N-1.

Alternative (simpler): skip `MADV_WILLNEED` entirely and let the OS page fault on demand.
At 1.45 GB/s throughput, the hardware prefetcher on sequential access may be sufficient —
measure if raw parse-on-demand beats the current preload+parse total.

**Expected gain:** if overlap is achievable, wall-clock could approach max(I/O, Parse)
instead of I/O + Parse, saving up to ~1997ms on the 300m file.

---

## 3. SIMD Hit Rate & Row Length Distribution

**Data:**
```
Avg Row Length:  13.79 bytes
Avg Name Len:     7.95 bytes
Max Name Len:    26 bytes
SIMD Iterations: 258,679,357
SIMD Hits:       250,324,006  (96.76%)
Rows via SIMD:   300,008,613
Rows via Tail:   7
```

**Observation:** 96.76% of 16-byte windows contain at least one newline. With avg row
13.79 bytes, most windows contain exactly one newline. The remaining 3.24% of windows
are mid-row spans (long city names, temperature fields). The tail scanner processes only
7 rows — completely negligible.

**Proposal: Double-newline inner loop**

Since most windows have exactly one newline, the inner `while final_mask != 0` loop runs
once per iteration for the common case. An explicit fast path for the single-newline case
(skip the loop, just `ctz` once and call `parse_row`) could reduce branch overhead.

```mojo
if final_mask & (final_mask - 1) == 0:   # power of 2 = exactly one bit set
    var nl = i + Int(count_trailing_zeros(final_mask))
    parse_row(map, ptr, row_start, nl, metrics)
    row_start = nl + 1
else:
    while final_mask != 0: ...  # existing multi-newline path
```

**Risk:** adds a branch. Only worth it if the predictor saturates on the single-newline case.
Measure carefully — A.1 in the Failed Optimizations appendix shows SIMD changes can regress.

---

## 4. SIMD Miss Samples

**Data:**
```
Sample 1: [ San Antonio;31.0 ]
Sample 2: [ etropavlovsk-Kam ]
Sample 3: [ sk-Kamchatsky;-0 ]
Sample 4: [  Havasu City;31. ]
Sample 5: [ erston North;9.1 ]
```

**Observation:** Misses are mid-row spans from long city names like "Petropavlovsk-Kamchatsky"
(24 chars) and "Lake Havasu City" (16 chars). These are expected and unavoidable — a 16-byte
window that falls entirely inside a station name produces no newline. There is no pathological
pattern (e.g. no alignment artifact, no systematic miss on any one station).

**Proposal: No action needed on miss rate itself.**

The 3.24% miss rate is near-optimal for this dataset. However, the samples confirm that
the `name_start` pointer maintained across SIMD iterations is correct even through multi-block
names — useful regression-detection value for future changes to the row scanner.

Consider keeping the miss sampler behind `--analyze` permanently (already done) as a
**correctness canary**: if a future parser change causes unexpected miss patterns (e.g.
100% miss rate, or misses containing newlines), it surfaces immediately.

---

## 5. Hash Map Occupancy (2.52%)

**Data:**
```
Thread 0–7:  413 entries / 16384 capacity  (2.52% used)
AVERAGE:     2.52% occupancy
```

**Observation:** The hash table allocates 16,384 `MapEntry` slots (48 bytes each = **768 KB**)
but only 413 are ever populated. Each thread carries its own copy → **8 × 768 KB = 6 MB**
total. L2 cache on M2 is 4 MB per cluster, so the working set spills.

**Proposal: Reduce CAPACITY to the next power-of-two above 413**

The perfect hash function uses `(k * MULTIPLIER) >> SHIFT`. The `SHIFT` parameter controls
effective table size: `2^(64 - SHIFT)`. Current SHIFT=50 → 2^14 = 16,384 slots.

Try `SHIFT=54` → 2^10 = 1024 slots (49 KB per thread, 392 KB total across 8 threads —
fits in L1/L2). Recalibrate `MULTIPLIER` to avoid collisions at the new size.

```mojo
struct PerfectStationMap[
    CAPACITY: Int = 1024,
    MULTIPLIER: UInt64 = <recalibrated>,
    SHIFT: Int = 54,
    ...
```

**Risk:** requires re-deriving a collision-free multiplier for 413 stations at the new
capacity. Run the existing `--analyze` collision check to validate. A.2 in the Failed
Optimizations appendix notes that key-loading changes can regress — benchmark carefully.

**Expected gain:** better L1/L2 residency for the map data, potentially meaningful for
the 100m benchmark where the map is accessed ~100M times in a short window.
