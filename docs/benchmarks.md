# 1BRC Mojo — Benchmarks & Environment

This document defines the benchmarking environment, metrics, and standardized results for the 1BRC Mojo implementation.

## Performance Metric Definitions

The `entrypoints/bench.sh` tool reports two primary metrics:

1.  **System Wall-Clock (Total Duration)**: The end-to-end time measured by the shell. It includes process startup, memory-mapping (`mmap`), page-cache warming, the parallel parse, final result merging, and shell overhead.
2.  **Mojo Internal Parse Time (Engine Throughput)**: The duration of the specialized `parallelize` parse stage alone, measured internally by Mojo using `perf_counter_ns`. This is the "pure" throughput of the CPU processing RAM-cached data.

## Environment Setup (pixi)

The project uses [pixi](https://pixi.sh) for reproducible environment management.

```bash
pixi install        # create/update the environment
pixi run build      # compile src/perf.mojo → bin/perf_bin with -O3
pixi run bench      # warm-cache benchmark (default: measurements_300m.txt, 5 runs)
pixi run analyze    # deep metrics: collisions, distribution, and internal timing
```

## Profiling & Analysis

- **Deep Analysis:** `entrypoints/analyze.sh` (or `pixi run analyze`) tracks hash collisions and deep parser metrics with minimal overhead.

## Standardized Benchmark Results (Warm cache, MacBook Air M2)

| Dataset | File size | Wall-Clock (Total) | Mojo Parse (Engine) | Engine Throughput |
|---|---|---|---|---|
| **100m** | 1.3 GB | ~190ms | ~140ms | **714.28 M rows/s** |
| **300m** | 3.9 GB | ~720ms | ~550ms | **545.45 M rows/s** |
| **600m** | 7.7 GB | ~10070ms | N/A | **60 M rows/s** (SSD Bound) |

---
*For historical performance data, see [Performance Log](performance_log.md).*
