# CPU, GPU, and Hybrid Execution Recommendation

## Recommendation

Keep the CPU implementation as the correctness and end-to-end performance
reference. Keep GPU work isolated until parsing, aggregation, and input
preparation all pass their individual gates.

Pursue the GPU as a bounded research track. The most credible destination is a
heterogeneous implementation in which the CPU and GPU process independent byte
ranges and merge their 413-station result maps. Do not use a fixed 50/50 split:
assign work according to measured CPU and GPU throughput while both are active.

The occupied scan and temperature-only kernels have passed their gates. On the
100M input the GPU counted newlines 2.63–2.71x as fast as the parallel CPU SIMD
scanner. Adding exact fixed-point temperature parsing reduced the advantage to
1.30–1.34x. The next gate is dense station indexing and workgroup aggregation.
Input preparation remains a separate blocker: the warm copied-buffer path took
193–245 ms before either kernel.

## Assessment of the CPU Kernel

The CPU architecture is strong and appropriately specialized for 1BRC:

- The 16-byte NEON newline scan uses an efficient SWAR mask-packing technique.
- Temperature parsing uses one backward 64-bit load and branchless integer math.
- The generated perfect hash avoids string comparison, collision probing, and
  allocation in the hot path.
- Thread-local maps avoid atomics and are merged after parsing.
- Compile-time tracker types provide a useful zero-cost instrumentation pattern.

The remaining CPU opportunities are refinements rather than a new algorithm:

1. Keep the 16-byte newline loop. A current-mask four-vector/64-byte experiment
   did not produce a repeatable 5% improvement under normal concurrent use.
2. Treat `@align(64)` as a neutral allocation-base setting. Compiler inspection
   shows a 32-byte `MapEntry` stride with a 64-byte-aligned allocation; the
   isolated 2026-07-30 test therefore did not compare 64- and 32-byte slots.
3. Keep compact statistics. The rejected native-width experiment changed the
   entry from 32 to 48 bytes as well as changing accumulator arithmetic, so it
   rejects that combined variant rather than isolating either effect.
4. Keep the ordinary newline-mask loop and its `reduce_or()` guard. Peeling was
   neutral; removing the guard improved parse slightly but did not improve wall.
5. Keep one equal-byte task per logical core. Current analysis measured only
   3.52% closing task skew, so work stealing has no demonstrated target.
6. Use demand-paged mmap below 2 GiB. Removing `MADV_WILLNEED` improved warm
   end-to-end wall time by 9.85% and 23.89% in paired comparisons.
7. Do not shift the continuous scanner by the minimum row length. The 413-name
   universe has a three-byte minimum, making byte 7 the earliest legal newline,
   but a global shift skips only seven bytes per worker. Reapplying the skip
   after every row would serialize the scanner and commonly issue one 16-byte
   load per roughly 13.8-byte record, potentially increasing total loaded bytes.

Software prefetching, SIMD gathers, staged parsing, smaller sparse maps, and a
SIMD reverse scan have already shown poor or neutral results and should not be
prioritized without evidence that compiler or hardware behavior has changed.

### Compiler inspection checkpoint

The optimized Apple M3 assembly for checkpoint `be84477` is already strong:
`parse_row()` and map updates are fully inlined, analysis trackers disappear
from the release specialization, the 16-byte newline loop has no body spills,
and temperature parsing lowers to compact bitfield and conditional-select
instructions. The installed nightly exposes optimized assembly and unoptimized
LLVM IR, but no supported MLIR dump.

The safety issue found by inspection is repaired in `c44c4d3`. Record-dependent
integer loads declare `alignment=1`, and each chunk peels one bounded first row
starting at the earliest legal newline position. The steady-state assembly
retains the same unaligned load and has no new per-row safety branch. The mmap
and forced-streaming oracle includes `Wau;0.0` as the shortest legal first row.

Two map candidates were tested and restored:

- Compiling first-insert bookkeeping only for analysis mode removed the release
  branch at the existing 32-byte stride. Both comparisons favored it by
  1.34–1.62% wall and 1.88–2.66% parse, below the 5% promotion threshold.
- A 16-byte stats-only entry preserved the hash configuration but was
  0.19–0.25% slower wall and about 1.18% slower parse in the two adjacent
  comparisons. Keep the 32-byte entry.

The remaining CPU candidates, in order, are:

1. Replace the full 16,384-slot-per-worker merge scan with a runtime loop over
   the 413 generated occupied slots.
2. For streaming, avoid retaining an unused mmap and test a single reusable
   buffer. The current two buffers are synchronous rather than overlapping I/O
   with parsing.
3. Only then try earlier hash scheduling or a packed statistics header. Reject
   the packed form before timing unless its assembly materially reduces memory
   operations without spills or a longer instruction path.

## Regenerated CPU Evidence

The 2026-07-30 baseline uses the original datasets, a correctness oracle, fatal
build/runtime handling, raw sample retention, and reduced-priority execution
while the machine remains in normal use.

| Dataset | Mode | Wall median | Wall MAD | Parse median |
|---|---|---:|---:|---:|
| 100M | mmap | 215.320 ms | 1.059 ms | 129.051 ms |
| 300M | streaming | 992.920 ms | 43.698 ms | 956.587 ms |
| 600M | streaming | 3168.349 ms | 108.689 ms | 2940.930 ms |
| 1B | streaming | 5274.523 ms | 134.611 ms | 5058.483 ms |

The current 100M mmap parse median is close to the historical 123 ms entry.
The apparent 300M slowdown is dominated by a changed execution path: the 3.85
GiB file previously fell below a 4 GiB streaming cutoff but now exceeds the
source's 2 GiB cutoff. Do not prioritize parser rollback from those old numbers.

After upgrading from Mojo `0.26.3.0.dev2026031505` to
`1.0.0b3.dev2026073014`, two repeatable bounded 100M mmap series measured
216.809 ms and 214.044 ms wall median, versus 215.320 ms before the upgrade.
Treat that as neutral. Their 127.343 ms and 126.465 ms parse medians are about
2% lower than the previous 129.051 ms, below the 5% promotion threshold.

One earlier upgraded series was roughly 11% faster, but controlled repeats
under standalone Mojo, the matching MAX runtime, and the obsolete
`register_passable` annotation did not reproduce it. This is cross-session
drift, not compiler evidence.

The regenerated Mojo 1.0 streaming curve is:

| Dataset | Wall median | Wall MAD | Parse median | Parse throughput |
|---|---:|---:|---:|---:|
| 300M | 1248.258 ms | 13.385 ms | 1221.664 ms | 245.57 M rows/s |
| 600M | 2479.582 ms | 9.685 ms | 2453.234 ms | 244.58 M rows/s |
| 1B | 4126.034 ms | 61.974 ms | 4098.138 ms | 244.01 M rows/s |

The path sustains 3.37–3.39 GB/s and scales almost exactly with input size.
Compared with the prior run, 300M is 25.72% slower but 600M and 1B are about
21.8% faster. The old 300M point was not representative of sustained
large-file throughput; the new curve is the appropriate baseline for CPU and
future hybrid experiments.

The isolated `MapEntry` alignment experiment did not justify a source change.
One A leg landed in a faster whole-machine session, but the closing unaligned
B2 versus aligned A2 comparison differed by only −0.44% wall and −2.82% parse.
Keep the annotation as a neutral incumbent. It aligns the allocation base in
this compiler; it does not pad each array element to 64 bytes.

The isolated 64-byte newline scan also did not justify a source change. Its
three adjacent B/A comparisons were +8.39%, −1.74%, and −1.60% wall and
+7.70%, −5.94%, and −1.29% parse. The two later wall comparisons favored the
unroll by less than 2%, and the parse result did not repeat. Keep the simpler
16-byte loop.

The current analysis profile reports 96.77% newline-hit blocks, 80.15%
single-newline hit blocks, eight scalar-tail rows, and 3.52% closing task skew.
Despite the high single-newline share, an isolated peeled loop was neutral.
Native-width statistics and mask-guard removal were also rejected.

Lazy mmap is the only promoted candidate from the old-document audit. Removing
`MADV_WILLNEED` makes internal parse time include more page-fault work, but
reduces warm end-to-end wall time materially. Cold-cache behavior is not
claimed because shared system caches were not flushed during normal PC use.

## GPU Evidence

The CPU-shaped parser prototype used:

- 256 total GPU threads;
- `block_dim=1`;
- a serial byte-by-byte scan within each thread;
- eight scalar loads to reconstruct a temperature word;
- one 16,384-slot sparse result table per thread; and
- serial initialization of every private table.

Its result state alone was approximately:

```text
16,384 slots × 6 Int64 values × 8 bytes × 256 threads
= 192 MiB
```

This leaves most GPU SIMD lanes inactive and gives each thread a 768 KiB working
set. The experiment confirms that the CPU-shaped chunking model maps poorly to a
GPU. It does not establish that an occupied, cooperative GPU kernel is slower.

The occupied scan-only prototype uses 256 blocks of 256 threads. Adjacent lanes
perform coalesced grid-stride byte reads and write private newline counters, so
there is no atomic or shared-table contention in this gate.

| 100M resident-data scan | CPU SIMD | GPU kernel | GPU advantage |
|---|---:|---:|---:|
| First series median | 61.386 ms | 22.620 ms | 2.71x |
| Warm repeat median | 62.357 ms | 23.685 ms | 2.63x |

Both series produced exactly 99,999,387 newlines before and after timing. The
warm GPU series had 1.551 ms MAD and 3.313 ms IQR under normal machine use,
without weakening an effect above 160%.

The current high-level input path still copies the mmap into a Metal
`DeviceBuffer`. It took 2,077.689 ms immediately after materialization and
245.106 ms with warm file data. The cold number includes file faults; the warm
number alone is enough to show that a full-file copy erases the kernel
advantage. Raw samples are under
`results/benchmarks/20260730-gpu-scan-{cold,warm}/`.

The temperature-only kernel reads the four relevant temperature bytes at every
newline and writes one row count and temperature sum per GPU thread. It does
not hash station names or aggregate by station.

| 100M temperature parsing | CPU SIMD | GPU kernel | GPU advantage |
|---|---:|---:|---:|
| First series median | 79.495 ms | 61.286 ms | 1.30x |
| Warm repeat median | 79.570 ms | 59.211 ms | 1.34x |

Both series produced 99,999,387 rows and an exact fixed-point sum of
17,828,649,656 before and after timing. Parsing consumes most of the scan-only
advantage: station indexing and aggregation have only about 20 ms of isolated
headroom over the equivalent CPU temperature parser. Raw samples are under
`results/benchmarks/20260730-gpu-temperature-{a,warm}/`.

## Proposed GPU Architecture

Use a workgroup-oriented kernel:

1. Process the file in large tiles so GPU resource size is bounded and disk I/O
   can be pipelined.
2. Launch conventional workgroups, such as 256 threads, rather than one-thread
   blocks.
3. Have SIMD groups load contiguous byte regions cooperatively and use vote,
   shuffle, or prefix operations to identify row boundaries.
4. Apply the CPU's backward fixed-point temperature parsing technique to rows
   identified by the group.
5. Map each station into a dense `0..412` index.
6. Aggregate into one compact 413-entry table in threadgroup memory.
7. Initialize that table cooperatively.
8. Flush one partial table per workgroup and reduce the partial tables in a
   second kernel or on the CPU.

This design addresses the artificial costs in the prototype:

- enough threads to occupy the GPU;
- coalesced input reads;
- no per-thread sparse table;
- no global atomic update for every row; and
- bounded result traffic.

It does not change the workload's low arithmetic intensity. The GPU still has
little computation with which to amortize memory access, and variable-length
rows still introduce divergent control flow. The goal is therefore efficient
bandwidth use and latency hiding, not increased mathematical density.

## Unified Memory Strategy

Unified memory means the CPU and GPU use the same physical memory system. It
does not guarantee that a normal file mapping is directly usable by a Mojo GPU
kernel, nor does it provide separate CPU and GPU bandwidth.

Evaluate input paths in this order:

1. A shared Metal buffer wrapping an aligned file mapping without a full copy.
2. Direct file reads into a GPU-visible shared allocation.
3. A staged host-to-device copy only as a fallback.

The first two options may require Metal interop outside the current high-level
Mojo buffer API. Treat zero-copy behavior as something to verify with timing and
memory counters, not infer from the term "unified memory."

## CPU and GPU Together

Data partitioning is preferable to splitting the parsing pipeline into CPU and
GPU stages. Each processor should parse and aggregate its own ranges, with no
shared hot-loop state.

If CPU throughput is `C` and GPU throughput is `G`, the ideal fractions are:

```text
CPU fraction = C / (C + G)
GPU fraction = G / (C + G)
```

A 50/50 split is appropriate only when their effective concurrent throughputs
are equal. With the previous GPU measurements, the ideal GPU share would have
been only about 9%, and the theoretical gain before overhead and contention
would have been about 10%.

Use large tiles and calibrate throughput while CPU and GPU run concurrently.
Their isolated rates are insufficient because they share memory bandwidth,
power, and thermal capacity. Consider using only performance CPU cores alongside
the GPU if efficiency cores or full-CPU utilization create a long tail or reduce
GPU throughput.

## Evaluation Plan and Stop Conditions

Before comparing implementations:

1. Pass exact mmap and forced-streaming output against the reference oracle.
2. Alternate variants in close pairs (`A-B-B-A`) under normal concurrent use.
3. Preserve all raw samples and report median, MAD, and IQR.
4. Use wall-clock time for promotion and parse time only for diagnosis.
5. Treat effects below 5% as inconclusive unless repeated evidence clearly
   exceeds observed dispersion.

Build the GPU investigation incrementally:

1. **Passed:** count newlines on resident data and materially exceed the CPU
   scanner.
2. **Passed:** add row and temperature parsing without aggregation.
3. **Next:** add dense station indexing and threadgroup aggregation.
4. Measure input preparation, kernel execution, and result reduction separately.
5. Compare CPU-only, GPU-only, fixed-split hybrid, and throughput-weighted hybrid.
6. Repeat on both warm resident input and cold or larger-than-memory input.
7. Require exact result equivalence at every stage.

Stop the investigation if any of these remain true after the workgroup redesign:

- the scan-only kernel cannot materially exceed the CPU byte scanner;
- adding aggregation collapses throughput because of divergence or contention;
- input preparation erases the kernel advantage;
- concurrent CPU and GPU throughput is no better than CPU-only throughput; or
- SSD throughput determines end-to-end time for the target dataset.

## Decision

The CPU implementation remains the performance and correctness reference.
Use the bounded-first-row/native-16-byte newline loop, the 32-byte compact map
entry, one equal-byte task per logical core, and demand-paged mmap below 2 GiB.
Keep `@align(64)` only as a neutral allocation-base setting. Controlled
experiments rejected the 64-byte unroll, removal of that base alignment,
native-width statistics, release-only insert-branch removal, 16-byte map
entries, peeled newline handling, mask-guard removal, and work stealing. The
regenerated streaming curve and lazy-mmap series are the performance baselines
for future comparisons.

The GPU byte scanner and temperature parser are fast enough to justify one
workgroup-aggregation experiment. This does not yet justify a GPU or hybrid
production path: the current copied input path is already slower than the CPU
parser end to end, and station indexing plus aggregation may consume the
remaining 1.30–1.34x kernel advantage. Continue in the isolated prototype with
explicit stop conditions. Promote a GPU or hybrid path only if it wins on exact,
end-to-end wall time with measured input preparation.
