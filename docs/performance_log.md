# 1BRC Mojo — Performance Log

## Occupied GPU Newline Scanner — 2026-07-30

The stage-one Metal prototype uses 256 blocks of 256 threads, coalesced
grid-stride byte reads, and one private newline counter per thread. It was
compared with an eight-thread CPU scanner using the production 16-byte
SIMD/SWAR mask. Five CPU-GPU-GPU-CPU pairs were retained per series under
normal concurrent machine use.

| 100M series | CPU median | CPU MAD | GPU median | GPU MAD | Ratio |
|---|---:|---:|---:|---:|---:|
| First run | 61.386 ms | 0.304 ms | 22.620 ms | 0.617 ms | 2.71x |
| Warm repeat | 62.357 ms | 0.938 ms | 23.685 ms | 1.551 ms | 2.63x |

Both paths counted exactly 99,999,387 newlines before and after timing. The
resident-data GPU scanner sustains 58.25–60.99 GB/s versus 22.12–22.47 GB/s
for the CPU scanner, so the first GPU gate passes.

The copied input path does not pass end to end. Staging 1,379,614,933 bytes
into a Metal `DeviceBuffer` took 2,077.689 ms immediately after dataset
materialization and 245.106 ms on the warm repeat. Treat zero-copy or direct
GPU-visible input as a required independent track. Raw samples and metadata are
under `results/benchmarks/20260730-gpu-scan-{cold,warm}/`.

### Temperature parsing without aggregation

The second kernel retains the coalesced byte scan and parses the four
fixed-point temperature bytes at every newline. It writes only one row count
and temperature sum per GPU thread. The CPU reference uses the same 16-byte
SIMD newline mask and performs the same temperature arithmetic.

| 100M series | CPU median | CPU MAD | GPU median | GPU MAD | Ratio |
|---|---:|---:|---:|---:|---:|
| First run | 79.495 ms | 0.127 ms | 61.286 ms | 2.994 ms | 1.30x |
| Warm repeat | 79.570 ms | 0.220 ms | 59.211 ms | 2.098 ms | 1.34x |

Both series produced exactly 99,999,387 rows and a fixed-point temperature sum
of 17,828,649,656 before and after timing. Temperature parsing preserves a
repeatable GPU advantage but consumes most of the scan-only lead. Proceed to
one station-indexing and dense workgroup-aggregation experiment. Raw evidence
is under `results/benchmarks/20260730-gpu-temperature-{a,warm}/`.

## Mojo 1.0 Nightly Upgrade — 2026-07-30

Mojo `1.0.0b3.dev2026073014` passes the 413-station oracle in mmap and forced
streaming modes. On the bounded 100M mmap benchmark, two repeatable 11-sample
series measured 216.809/127.343 ms and 214.044/126.465 ms for wall/parse
medians, versus 215.320/129.051 ms before the upgrade. Treat the upgrade as
performance-neutral end-to-end at this scale.

An earlier 190.989/113.160 ms series did not reproduce under either standalone
Mojo or the matching MAX runtime, or with the obsolete `register_passable`
annotation restored. It is retained as cross-session drift despite its low
within-series MAD. Raw samples and environment metadata are under the
`results/benchmarks/20260730-mojo-1.0b3*` directories.

The upgraded streaming path sustains nearly constant throughput:

| Dataset | Samples | Wall median | Wall MAD | Parse median | Rows/s |
|---|---:|---:|---:|---:|---:|
| 300M | 11 | 1248.258 ms | 13.385 ms | 1221.664 ms | 245.57M |
| 600M | 11 | 2479.582 ms | 9.685 ms | 2453.234 ms | 244.58M |
| 1B | 11 | 4126.034 ms | 61.974 ms | 4098.138 ms | 244.01M |

This corresponds to 3.37–3.39 GB/s. The prior 300M point was 25.72% faster,
but the upgraded 600M and 1B wall medians are 21.74% and 21.77% faster. Treat
the new linear curve as the current sustained streaming baseline.

### `@align(64)` isolation

An 11-sample-per-leg `A-B-B-A` comparison removed only `@align(64)` from
`MapEntry`. The closing B2/A2 comparison favored the unaligned variant by
0.44% wall and 2.82% parse, below the 5% threshold. A1 was a fast-session
outlier and made the paired directions contradictory. The change was rejected
and alignment remains in the source. Later compiler inspection established that
the annotation aligns the allocation base to 64 bytes while entries retain a
32-byte stride. Raw evidence is under `results/benchmarks/20260730-map-align-*`.

### Four-vector newline scan

A current-mask four-load/64-byte unroll passed the full correctness gate but
did not produce a repeatable 5% improvement. Three adjacent B/A comparisons
measured +8.39%, −1.74%, and −1.60% wall, and +7.70%, −5.94%, and −1.29%
parse. The opening A block was a fast-session outlier and the third B block was
heavily disturbed by concurrent machine use. The two later wall comparisons
favored the unroll by less than 2%, so it was rejected and the 16-byte loop was
restored. All 66 samples are under
`results/benchmarks/20260730-unroll-*`.

### Historical-candidate audit

Four additional old-document candidates were isolated with 11 samples per
block:

- Native-width `StationStats` regressed the reliable closing comparison by
  0.79% wall and 5.01% parse. Compact fields remain.
- Peeling the first newline from each nonzero mask changed the closing pair by
  +0.10% wall and +0.36% parse. The ordinary loop remains.
- Removing the `reduce_or()` guard improved parse by 1.55% but regressed wall by
  1.26% in the closing pair. The guard remains.
- Removing `MADV_WILLNEED` improved wall by 9.85% and 23.89% in the opening and
  closing comparisons. Parse time increased because demand faults moved inside
  the parse phase, but total process time fell. Lazy mmap is retained for files
  below 2 GiB.

Current analysis found 96.77% SIMD hit blocks, 80.15% single-newline hit
blocks, only eight scalar-tail rows, and 3.52% closing task skew. These results
do not justify work stealing. Raw evidence is under
`results/benchmarks/20260730-{native-stats,peeled-newline,mask-guard,mmap-advice}-*`.
Cold-cache mmap advice was not tested because flushing shared system caches
would disrupt concurrent machine use.

### Assembly-led parser and map follow-up

Checkpoint `c44c4d3` declares the record-dependent integer loads as unaligned
and peels one bounded first row per chunk. The optimized steady-state loop has
no added safety branch, and the 413-station oracle passes in mmap and forced
streaming modes with the earliest legal newline at byte 7.

Two 11-sample-per-leg experiments retained the ordinary 32-byte implementation:

| Candidate comparison | Wall delta | Parse delta | Decision |
|---|---:|---:|---|
| Release insert branch B1 vs A1 | −1.62% | −2.66% | Below threshold |
| Release insert branch B2 vs A2 | −1.34% | −1.88% | Below threshold |
| 16-byte entry B1 vs A2 | +0.25% | +1.17% | Reject |
| 16-byte entry B2 vs A3 | +0.19% | +1.18% | Reject |

Raw samples and environment metadata are under
`results/benchmarks/20260730-{asm-safety-baseline,release-insert-branch,stats16}-*`.

The final retained lazy-mmap source measured 165.741 ms wall and 140.098 ms
parse medians in an additional 11-sample series. Its 4.98% wall relative MAD
records heavier concurrent-use noise without changing the decision.

## Validated Baseline — 2026-07-30

These results use the current correctness gate and noise-tolerant harness under
normal concurrent machine use. Raw samples and environment metadata are stored
under `results/benchmarks/20260730-normal-use/`.

| Dataset | I/O mode | Samples | Wall median | Wall MAD | Parse median |
|---|---|---:|---:|---:|---:|
| 100M | mmap | 11 | 215.320 ms | 1.059 ms | 129.051 ms |
| 300M | streaming | 11 | 992.920 ms | 43.698 ms | 956.587 ms |
| 600M | streaming | 11 | 3168.349 ms | 108.689 ms | 2940.930 ms |
| 1B | streaming | 7 | 5274.523 ms | 134.611 ms | 5058.483 ms |

## Historical Records — Not Comparable

The entries below predate the current correctness gate and raw-sample capture.
They mix different I/O thresholds, machine pressure, summary conventions, and
occasionally minimum versus median results. Keep them as experiment history,
but do not use them as a current baseline or to attribute a regression.

| Date | Commit/Version | Dataset | System Wall-Clock (median) | Engine Throughput (rows/s) | Notes |
|---|---|---|---|---|---|
| 2026-03-17 | `600m-11000ms` | 600M | 11000ms | - | Baseline for 600M |
| 2026-03-17 | Current | 600M | 10070ms | - | Current optimized state |
| 2026-03-17 | Current | 300M | 720ms | 545.45M | Standardized run |
| 2026-03-17 | Current | 100M | 190ms | 714.28M | Standardized run |
| 2026-03-20 | Post-Cleanup | 300M | 612ms | 666.67M | After removing experimental vectorized code |
| 2026-03-20 | Streaming I/O | 300M | 624ms | 652.17M | Explicit pread + Double-buffering |
| 2026-03-20 | Streaming I/O | 600M | 6993ms | 112.71M | Significant gain over mmap on MacOS (600M=7.8GB) |
| 2026-03-20 | Comptime Opt | 300M | 632ms | 638.30M | Added Likely and unlikely |
| 2026-03-20 | Aligned Streaming | 100M | 137ms | 729.92M | With 4MB blocks and F_NOCACHE |
| 2026-03-20 | Lookahead v2 | 600M | 7055ms | 85.05M | Sustainable streaming beyond 4.8GB RAM |
| 2026-03-20 | Gap Recovery | 600M | 1836ms | 326.73M | Threshold lowered to 4GB (3.8x gain over mmap) |
| 2026-03-21 | Ownership Opt | 300M | 413ms | 725.82M | Idiomatic ownership and `ref` in map merge |
| 2026-03-21 | No Signature | 600M | 1691ms | 354.82M | Removed signature check from hot path |
| 2026-03-21 | Perfect Hash | 600M | 1733ms | 354.82M | made table smaller |
| 2026-03-21 | No Signature | 600M | 1630ms | 354.82M | No signature + no computer ram pressure |
| 2026-03-22 | 2-Load Hash | 600M | 1583ms | 354.82M | 2-Load Hash |
| 2026-03-22 | 4x Unroll | 300M | 525ms | - | Unrolled SIMD loop |
| 2026-03-22 | Combined Mask | 300M | 424ms | - | Combined reduction checks in unrolled loop |
| 2026-03-22 | 32B MapEntry | 300M | 431ms | - | Reduced MapEntry from 48B to 32B (Min result) |
| 2026-03-22 | Branchless Update | 300M | 418ms | - | Branchless min/max + peeled newline loop (Min) |
| 2026-03-22 | Magic Movemask | 300M | 401ms | - | Record. Magic 64-bit Movemask + rbit/clz |
| 2026-03-22 | Refined Movemask | 300M | 396ms | - | **New Record**. 0x0F masking + likely() loops. |
| 2026-03-22 | Magic Movemask | 100M | 123ms | - | **Record**. |
| 2026-03-22 | Magic Movemask | 600M | 1.63s | - | **Record**. |
| 2026-03-22 | Magic Movemask | 1B | 4.36s | - | **Record**. (Previous best: 10.4s) |
| 2026-03-22 | Magic Movemask | 1B | 4.3604s | - | Updated Movemask with 0x0F masking + likely() loops. |
| 2026-03-23 | 32B MapEntry | 1B | 4223ms | 236.80M | **New Record**. 32-byte MapEntry optimization. |
| 2026-04-22 | Native Width + Align | 300M | 1009ms | 297.32M | Refactored SIMD loop to 16B native width + @align(64). |
