# 1BRC Mojo — I/O & Parallelism

## I/O Strategy (Hybrid Model)

The strategy is chosen automatically based on file size to balance setup overhead vs. streaming stability:

| File size | Mode | Strategy | Reason |
|---|---|---|---|
| < 4 GB | `mmap` | `MADV_WILLNEED` | Pre-loads into RAM. Fastest for datasets that fit in available memory. |
| ≥ 4 GB | `pread` | `DoubleBufferedStream` | Streams in 4MB aligned blocks with `F_NOCACHE` to bypass macOS buffer cache thrashing. |

**Key Insight:** For massive files (1B rows), `mmap` on macOS can suffer from severe page-fault latency when memory pressure is high. Using explicit `pread` into circular buffers bypasses the VM subsystem's complexity and achieves near-peak NVMe throughput.

## Parallelization Pipeline

Data is processed using `std.algorithm.parallelize`, scaling linearly with `num_logical_cores()`. Thread-local storage eliminates contention.
