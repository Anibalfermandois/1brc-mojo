# 1BRC Benchmark Protocol and Current Baseline

Performance work is measured while the machine remains in normal concurrent
use. Background activity is expected; the harness preserves every sample and
reports robust dispersion rather than requiring an idle machine.

## Correctness Gate

Run this before accepting any timing:

```bash
pixi run check
```

The check generates a deterministic fixture containing all 413 stations and
compares both mmap and forced-streaming output with a Python oracle. It is large
enough to cross the streaming buffer boundary.

Build and runtime failures are fatal. The benchmark will not silently reuse a
stale binary or record a failed run as zero milliseconds.

## Benchmark Commands

The original datasets can be restored from historical Git objects:

```bash
entrypoints/materialize-dataset.sh 100m
entrypoints/materialize-dataset.sh 300m
entrypoints/materialize-dataset.sh 600m
entrypoints/materialize-dataset.sh 1b
```

Then run a baseline:

```bash
pixi run bench-100m
pixi run bench-300m
pixi run bench-600m
pixi run bench-1b
```

Each run uses reduced process priority, performs one warmup, pauses briefly
between samples, and writes raw CSV, summary statistics, source fingerprint,
toolchain, memory, load, and Git metadata under `results/benchmarks/`.

## Metrics

- **Wall clock** is the primary decision metric. It includes process startup,
  mmap or streaming setup, parsing, and merge work.
- **Internal parse time** is diagnostic. It measures the parallel parse region
  and excludes process startup and final result printing.
- **MAD** is median absolute deviation. It is the main noise measure because a
  concurrent-use interruption does not dominate it.
- No sample is automatically discarded.

For optimization A/B tests, alternate variants closely (`A-B-B-A`) and compare
paired percentage differences. Treat improvements below 5% as inconclusive
unless they repeat across sessions with dispersion comfortably below the
observed effect.

## Regenerated Baseline — 2026-07-30

Condition: normal concurrent machine use, `nice 10`, Mojo
`0.26.3.0.dev2026031505`, macOS `26.5.2`. The current 2 GiB threshold uses mmap
for 100M and streaming for 300M, 600M, and 1B.

| Dataset | Mode | Samples | Wall median | Wall MAD | Parse median | Parse throughput |
|---|---|---:|---:|---:|---:|---:|
| 100M | mmap | 11 | 215.320 ms | 1.059 ms | 129.051 ms | 774.89 M rows/s |
| 300M | streaming | 11 | 992.920 ms | 43.698 ms | 956.587 ms | 313.61 M rows/s |
| 600M | streaming | 11 | 3168.349 ms | 108.689 ms | 2940.930 ms | 204.02 M rows/s |
| 1B | streaming | 7 | 5274.523 ms | 134.611 ms | 5058.483 ms | 197.69 M rows/s |

The raw samples and per-dataset metadata are in
`results/benchmarks/20260730-normal-use/`. These results supersede older
headline numbers for current decisions.

## Mojo Nightly Upgrade Check — 2026-07-30

The project was upgraded to the standalone Mojo
`1.0.0b3.dev2026073014` package. The migration includes the 1.0 `def` syntax,
non-null untracked pointers, `CStringSlice` for POSIX paths, explicit unsafe
pointer indexing, implicit destruction constraints, and CPU `DeviceContext`
scheduling.

The deterministic 413-station oracle passes in both mmap and forced-streaming
modes. Two repeatable 100M mmap series on the final standalone environment
found:

| Series | Samples | Wall median | Wall MAD | Parse median | Parse MAD |
|---|---:|---:|---:|---:|---:|
| Pre-upgrade Mojo `0.26.3.0.dev2026031505` | 11 | 215.320 ms | 1.059 ms | 129.051 ms | 1.049 ms |
| Mojo 1.0 final source | 11 | 216.809 ms | 2.026 ms | 127.343 ms | 0.942 ms |
| Mojo 1.0 immediate repeat | 11 | 214.044 ms | 1.194 ms | 126.465 ms | 0.099 ms |

The upgrade is performance-neutral end-to-end at this scale; its repeatable
parse median is about 2% lower, below the 5% promotion threshold. An earlier
Mojo 1.0 series measured 190.989 ms wall and 113.160 ms parse with low
within-series MAD, but neither the standalone/MAX environment nor the obsolete
`register_passable` annotation reproduced it. It is retained as whole-session
drift, demonstrating that low MAD inside one series does not eliminate
cross-session noise.

Raw upgraded samples are in the audit directories matching
`results/benchmarks/20260730-mojo-1.0b3*`.

The post-upgrade streaming baseline is:

| Dataset | Samples | Wall median | Wall MAD | Parse median | Parse throughput |
|---|---:|---:|---:|---:|---:|
| 300M | 11 | 1248.258 ms | 13.385 ms | 1221.664 ms | 245.57 M rows/s |
| 600M | 11 | 2479.582 ms | 9.685 ms | 2453.234 ms | 244.58 M rows/s |
| 1B | 11 | 4126.034 ms | 61.974 ms | 4098.138 ms | 244.01 M rows/s |

This is a consistent sustained curve of 3.37–3.39 GB/s. Relative to the prior
run, 300M is 25.72% slower, while 600M and 1B are 21.74% and 21.77% faster
end-to-end. The new curve scales almost exactly with input size, so the old
300M result should not be extrapolated as sustained throughput and the old
600M/1B results should not be used to infer a current large-file regression.
Raw samples are in
`results/benchmarks/20260730-mojo-1.0b3-streaming/`.

## MapEntry Alignment Experiment — 2026-07-30

An `A-B-B-A` experiment compared the current `@align(64)` declaration (A)
with the annotation removed (B), using 11 samples per series on the 100M mmap
path. Both variants passed the mmap and forced-streaming oracle.

| Series | Variant | Wall median | Wall MAD | Parse median | Parse MAD |
|---|---|---:|---:|---:|---:|
| A1 | aligned | 183.592 ms | 4.366 ms | 115.259 ms | 1.380 ms |
| B1 | unaligned | 206.972 ms | 2.334 ms | 127.838 ms | 1.392 ms |
| B2 | unaligned | 206.039 ms | 1.339 ms | 126.620 ms | 0.298 ms |
| A2 | aligned | 206.958 ms | 1.687 ms | 130.291 ms | 1.736 ms |

A1 was a whole-session fast outlier. The adjacent closing comparison, B2
versus A2, was −0.44% wall and −2.82% parse. That is below the 5% threshold,
and the two pair directions contradict each other. Keep `@align(64)` and treat
the experiment as neutral. Raw samples are under
`results/benchmarks/20260730-map-align-*`.

## Four-Vector Newline Scan Experiment — 2026-07-30

The current 16-byte NEON loop (A) was compared with a four-load, 64-byte
unrolled loop (B). The candidate retained the current SWAR mask packing and
changed only the load/scan scheduling. Both variants passed the 413-station
oracle in mmap and forced-streaming modes. Eleven samples were retained for
each block under normal concurrent use.

| Series | Variant | Wall median | Wall MAD | Parse median | Parse MAD |
|---|---|---:|---:|---:|---:|
| A1 | 16-byte loop | 186.565 ms | 2.389 ms | 112.704 ms | 0.126 ms |
| B1 | 64-byte unroll | 202.225 ms | 1.812 ms | 121.385 ms | 0.353 ms |
| B2 | 64-byte unroll | 200.446 ms | 3.128 ms | 123.275 ms | 1.699 ms |
| A2 | 16-byte loop | 203.987 ms | 2.565 ms | 131.058 ms | 0.866 ms |
| B3 | 64-byte unroll | 212.101 ms | 7.479 ms | 124.735 ms | 4.860 ms |
| A3 | 16-byte loop | 215.546 ms | 2.779 ms | 126.371 ms | 1.883 ms |

The paired B/A changes were +8.39%, −1.74%, and −1.60% for wall time and
+7.70%, −5.94%, and −1.29% for parse time. A1 was another fast whole-machine
session, while B3 was visibly disturbed. The two later wall comparisons favor
the unroll by less than 2%, below the 5% threshold, and the parse effect did not
repeat. Reject the candidate and keep the simpler 16-byte loop. Raw evidence is
under `results/benchmarks/20260730-unroll-*`.

## Current Analysis Profile — 2026-07-30

The restored analysis-only counters produced the following 100M mmap profile:

| Metric | Value |
|---|---:|
| Parsed rows | 99,999,387 |
| 16-byte SIMD iterations | 86,225,929 |
| Blocks containing a newline | 83,437,851 (96.77%) |
| Single-newline hit blocks | 66,876,323 (80.15% of hits) |
| Multi-newline hit blocks | 16,561,528 |
| Scalar-tail rows | 8 |
| Fastest task | 62.157 ms |
| Slowest task | 64.428 ms |
| Closing task skew | 3.52% |

The eight tasks processed equal byte ranges. This does not support the old
45.77% skew claim or justify work stealing under the current runtime.

## Historical Candidate Retests — 2026-07-30

Each candidate used the same correctness gate, 100M mmap input, 11 retained
samples per block, and normal concurrent machine use.

| Experiment | A1 wall/parse | B1 wall/parse | B2 wall/parse | A2 wall/parse | Decision |
|---|---:|---:|---:|---:|---|
| Native-width statistics | 185.723 / 115.859 ms | 207.565 / 132.536 ms | 208.326 / 137.112 ms | 206.703 / 130.573 ms | Reject |
| Peeled first newline | 205.851 / 130.550 ms | 205.149 / 130.334 ms | 206.539 / 131.220 ms | 206.323 / 130.753 ms | Reject |
| Remove `reduce_or()` guard | 209.256 / 128.096 ms | 206.232 / 126.815 ms | 207.388 / 126.807 ms | 204.799 / 128.803 ms | Reject |
| Remove `MADV_WILLNEED` | 179.259 / 115.282 ms | 161.611 / 138.939 ms | 162.727 / 139.191 ms | 213.793 / 133.113 ms | Promote B |

Native-width statistics were 0.79% wall and 5.01% parse slower in the closing
pair. Peeling was neutral. Removing the mask guard saved about 1% parse in the
B blocks, but its closing wall result was 1.26% worse.

Removing `MADV_WILLNEED` was the only end-to-end win. It improved wall time by
9.85% in the opening pair and 23.89% in the closing pair. Demand faults move
into the measured parse region, explaining why parse time rises even as total
wall time falls. The result applies to the harness's warm-cache protocol;
cold-cache behavior remains unmeasured because system-wide cache flushing
would disrupt concurrent machine use.

Raw evidence is under
`results/benchmarks/20260730-{native-stats,peeled-newline,mask-guard,mmap-advice}-*`.

A final 11-sample series on the retained lazy-mmap source measured
165.741 ms wall median and 140.098 ms parse median. Its 4.98% wall relative MAD
reflects heavier concurrent-use noise, but the median still confirms the
end-to-end improvement. Raw evidence is under
`results/benchmarks/20260730-current-lazy-mmap/`.
