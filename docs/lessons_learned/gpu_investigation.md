# 1BRC Mojo — GPU Investigation

The Apple M3 GPU can scan resident 1BRC bytes materially faster than the
parallel CPU SIMD scanner. It is not yet faster end to end because the available
high-level Mojo path copies the input into a Metal buffer.

## Current Result

`src/gpu_scan.mojo` launches 256 blocks of 256 threads. Adjacent lanes read
adjacent bytes, each lane advances by the full grid width, and each lane writes
one private newline count. This isolates memory scanning from parsing,
aggregation, atomics, and shared-memory contention.

Five CPU-GPU-GPU-CPU pairs on the 1,379,614,933-byte input produced:

| Series | CPU SIMD median | GPU kernel median | GPU advantage |
|---|---:|---:|---:|
| First run | 61.386 ms | 22.620 ms | 2.71x |
| Warm repeat | 62.357 ms | 23.685 ms | 2.63x |

Both paths counted exactly 99,999,387 newlines before and after timing. The GPU
kernel sustained 58.25–60.99 GB/s while the eight-thread CPU scanner sustained
22.12–22.47 GB/s. The scan-only gate therefore passes.

## Input Constraint

The benchmark copies the mmap directly into a Mojo `DeviceBuffer` and times
that operation independently:

- 2,077.689 ms immediately after materializing the dataset, including cold file
  faults;
- 245.106 ms with warm file data.

Even the warm copy plus the median kernel is about 268.8 ms. The current CPU
implementation parses and aggregates the same 100M input faster than that, so
kernel throughput cannot justify production GPU execution while the full-file
copy remains.

Evaluate a Metal shared buffer wrapping aligned mapped memory or direct reads
into a GPU-visible shared allocation before making an end-to-end claim.
Apple's unified physical memory does not make an ordinary mmap GPU-visible
through the current high-level API automatically.

## Temperature Parsing Result

The second kernel parses the fixed-point temperature at each newline without
station hashing or aggregation. Per-thread row counts and temperature sums keep
result traffic bounded and provide an exact correctness oracle.

| Series | CPU temperature median | GPU temperature median | GPU advantage |
|---|---:|---:|---:|
| First run | 79.495 ms | 61.286 ms | 1.30x |
| Warm repeat | 79.570 ms | 59.211 ms | 1.34x |

Every run produced 99,999,387 rows and the fixed-point sum 17,828,649,656. The
temperature kernel therefore passes, but only about 20 ms separates it from
the equivalent CPU reference. Station-name handling and aggregation must fit
inside that remaining isolated headroom to preserve a kernel advantage.

## Why the CPU-Shaped Parser Failed

The earlier full parser used only 256 total GPU threads with one-thread blocks.
Each thread scanned serially and owned a 16,384-slot result table:

```text
16,384 slots × 6 Int64 values × 8 bytes × 256 threads = 192 MiB
```

Its 4,686 ms kernel and roughly 17,939 ms total time on 300M demonstrate that
CPU chunking, scalar scanning, and per-thread sparse aggregation map poorly to
the GPU. They do not contradict the occupied scan result.

## Remaining Gates

1. **Passed:** parse fixed-point temperatures without aggregation.
2. Map station names to the dense `0..412` universe.
3. Aggregate into one 413-entry table per workgroup and flush partial tables.
4. Remove or pipeline input preparation.
5. Compare exact GPU-only and throughput-weighted CPU+GPU execution end to end.

Stop if parsing destroys the scan advantage, shared-table contention collapses
throughput, input preparation remains dominant, or concurrent CPU+GPU
throughput fails to exceed CPU-only execution.
