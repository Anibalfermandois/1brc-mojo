# 1BRC Mojo — GPU Investigation

The Apple M3 GPU can scan resident 1BRC bytes materially faster than the
parallel CPU SIMD scanner. An Objective-C++ bridge can wrap Mojo's file mapping
in a Metal buffer without copying, but the first GPU access to the file-backed
VM region remains expensive and variable.

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

## Zero-copy input

The high-level Mojo benchmark copies the mmap into a `DeviceBuffer` and times
that operation independently:

- 2,077.689 ms immediately after materializing the dataset, including cold file
  faults;
- 245.106 ms with warm file data.

The direct-Metal proof in `src/gpu_zero_copy.mojo` instead passes the mmap
pointer to an Objective-C++ bridge. Metal's `newBufferWithBytesNoCopy` wrapped
the page-aligned 1.38 GB VM region in 0.057–0.085 ms. All dispatches returned
the exact 99,999,387 newline count.

Repeated bridge calls measured 21.373–28.492 ms, with a 22.729 ms median across
20 samples. A new buffer's first full dispatch remained variable: 186–723 ms
when the GPU touched it first and 70.954 ms after a CPU pre-touch. The primitive
therefore removes the explicit copy, not VM residency and first-access costs.

The bridge uses an MSL kernel. Mojo's public `DeviceBuffer` API cannot adopt the
external `MTLBuffer`, so Mojo-compiled kernels still use the copied path. Full
evidence is under
`results/benchmarks/20260731-metal-zero-copy/measurements_100m.md`.

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

The direct-Metal MSL version uses the no-copy mmap and measured a 45.356 ms
median across 15 repeated warm calls, with a 39.716–57.346 ms range. Against
the established 79.495–79.570 ms parallel CPU reference, equivalent warm
temperature-only work is approximately 1.75x faster. It also improves on the
copied Mojo GPU kernel's 59.211 ms warm median by about 23%.

First dispatch remains unsuitable for one-shot execution. GPU-first temperature
dispatches took 201–747 ms, and CPU pre-touch reduced the dispatch to 91 ms.
Context and runtime MSL compilation added another 49–55 ms. Full evidence is
under `results/benchmarks/20260731-metal-zero-copy/measurements_100m_temperature.md`.

## Direct-Metal station indexing

The retained compact-rank index was ported to MSL over the same no-copy input.
Two packed 4-byte loads reconstruct each eight-byte suffix; one unaligned
64-bit MSL load was incorrect, while eight scalar byte loads measured 344.242
ms median.

The packed form passed exact row, temperature, dense-ID, squared-ID, and invalid
counts. Two warm series measured 149.184 ms and 145.418 ms medians, for a
146.835 ms combined median across ten samples. The parallel CPU references span
135.773–145.157 ms, so direct Metal remains 1–8% slower and fails the material
win gate. Full evidence is under
`results/benchmarks/20260731-metal-zero-copy/measurements_100m_station.md`.

## Why the CPU-Shaped Parser Failed

The earlier full parser used only 256 total GPU threads with one-thread blocks.
Each thread scanned serially and owned a 16,384-slot result table:

```text
16,384 slots × 6 Int64 values × 8 bytes × 256 threads = 192 MiB
```

Its 4,686 ms kernel and roughly 17,939 ms total time on 300M demonstrate that
CPU chunking, scalar scanning, and per-thread sparse aggregation map poorly to
the GPU. They do not contradict the occupied scan result.

## Current decision

1. **Passed:** occupied newline scan and no-copy mmap wrapping for MSL kernels.
2. **Passed:** direct-Metal fixed-point temperature parsing at 1.75x the warm
   parallel CPU temperature reference.
3. **Failed:** direct-Metal compact-rank station indexing measured 146.835 ms
   warm median and did not beat the 135.773–145.157 ms CPU references.
4. **Stopped:** do not add aggregation; station indexing consumed the warm
   temperature lead before aggregation began.

Promote no GPU or hybrid path until exact one-shot end-to-end wall time beats
the CPU implementation under normal workstation use.
