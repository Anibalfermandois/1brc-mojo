# CPU, GPU, and Hybrid Execution Recommendation

## Recommendation

Keep the CPU implementation as the reference path and improve it before making
GPU execution part of the main program.

Pursue the GPU as a bounded research track. The most credible destination is a
heterogeneous implementation in which the CPU and GPU process independent byte
ranges and merge their 413-station result maps. Do not use a fixed 50/50 split:
assign work according to measured CPU and GPU throughput while both are active.

The previous GPU result does not rule this out. It measured an intentionally
underutilized kernel, not a GPU-shaped implementation. A redesigned kernel may
be competitive, but the workload's low arithmetic intensity, divergent parsing,
and shared memory bandwidth remain fundamental risks.

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
2. Keep `@align(64)` as a neutral incumbent. Its isolated 2026-07-30
   `A-B-B-A` test found only −0.44% wall and −2.82% parse for removing it in
   the reliable closing pair, below the 5% threshold.
3. Keep compact statistics. Native-width fields made the closing comparison
   0.79% slower wall and 5.01% slower parse without changing the 64-byte stride.
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
Keep the aligned layout.

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

## What the Previous GPU Experiment Established

The previous kernel used:

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

The documented data-transfer cost also does not explain the kernel result by
itself. The experiment copied the mapped file into a host buffer and then into a
device buffer, while the kernel remained roughly ten times slower than the CPU
parse phase. Occupancy, scalar scanning, and result layout were major limitations
in addition to memory traffic.

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

Then build the GPU investigation incrementally:

1. Count newlines on resident data and measure kernel-only throughput.
2. Add row and temperature parsing without aggregation.
3. Add dense threadgroup aggregation.
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
Use the native 16-byte newline loop, compact statistics, `@align(64)`, one
equal-byte task per logical core, and demand-paged mmap below 2 GiB. Controlled
experiments rejected the 64-byte unroll, unaligned entries, native-width
statistics, peeled newline handling, mask-guard removal, and work stealing.
The regenerated streaming curve and lazy-mmap series are the performance
baselines for future comparisons.

A GPU revisit is technically justified because the previous prototype did not
exercise the GPU effectively. The likely benefit is bounded: a large pure-GPU
victory is unlikely, while a moderate CPU+GPU improvement is plausible if the
GPU uses workgroup-local aggregation, the input is GPU-visible without a
full-file copy, and the CPU leaves meaningful shared-memory bandwidth available.

Before GPU work, inspect the optimized assembly and available compiler IR for
remaining CPU inefficiencies. Proceed with GPU work only after that review,
using an isolated prototype with explicit kill criteria. Promote a GPU or
hybrid path only if it wins on exact, end-to-end wall time.
