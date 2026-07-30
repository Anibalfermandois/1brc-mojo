# 1BRC Mojo — I/O & Parallelism

## I/O Strategy (Hybrid Model)

The strategy is chosen automatically based on file size to balance setup overhead vs. streaming stability:

| File size | Mode | Strategy | Reason |
|---|---|---|---|
| < 2 GiB | `mmap` | Demand-paged mapping | Avoids eager preload overhead and lets parsing fault pages as needed. |
| ≥ 2 GiB | `pread` | `DoubleBufferedStream` | Streams bounded 4 MiB blocks with `F_NOCACHE` to avoid page-cache thrashing. |

Each worker receives a shared, newline-aligned byte range. Reads are capped at
that range, so workers do not overlap or omit records. Aggregation merges by
stable perfect-hash slot; station names used for output come from the generated
canonical station table rather than reusable stream buffers.

## Parallelization Pipeline

Data is scheduled through a CPU `DeviceContext`. Each of the eight equal-byte
tasks owns its map, and maps are merged after parsing without hot-loop atomics.
The current 100M analysis measured only 3.52% closing task skew, so finer task
subdivision or atomic work stealing is not part of the active path.
