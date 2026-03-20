# 1BRC Mojo — I/O & Parallelism

## I/O Strategy (mmap)

A `madvise` strategy is chosen based on file size:

| File size | Strategy | Reason |
|---|---|---|
| < 8 GB | `MADV_WILLNEED` | Pre-loads into RAM. Engine Throughput is CPU-bound. |
| ≥ 8 GB | `MADV_SEQUENTIAL` | Streams from disk. Engine Throughput is I/O-bound. |

**Key Insight:** For the 3.9 GB file, `MADV_WILLNEED` adds ~500ms–700ms to the "System Total" but allows the "Engine Peak" to reach its full potential.

## Parallelization Pipeline

Data is processed using `std.algorithm.parallelize`, scaling linearly with `num_logical_cores()`. Thread-local storage eliminates contention.
