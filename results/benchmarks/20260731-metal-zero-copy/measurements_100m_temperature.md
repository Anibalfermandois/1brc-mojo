# Metal mmap zero-copy temperature gate

## Result

The direct-Metal temperature kernel passed exact correctness on the no-copy
file mapping. Every dispatch returned 99,999,387 rows and the fixed-point sum
17,828,649,656 for the 1,379,614,933-byte 100M input.

- Mojo: `1.0.0b3.dev2026073014 (86c799a2)`
- CPU/GPU: Apple M3
- VM page size: 16,384 bytes
- Metal buffer length: 1,379,631,104 bytes
- Grid: 256 blocks of 256 threads
- Process priority: `nice -n 10`
- Machine condition: normal concurrent workstation use

## Measurements

| Session | Order | Context and runtime MSL compile | No-copy wrap | First dispatch wall | First dispatch GPU | Warm wall median | Warm wall range |
|---|---|---:|---:|---:|---:|---:|---:|
| A | GPU first | 54.802 ms | 0.085 ms | 747.482 ms | 63.247 ms | 45.602 ms | 43.985–57.346 ms |
| B | GPU first | 49.286 ms | 0.086 ms | 201.025 ms | 85.373 ms | 45.867 ms | 43.884–50.873 ms |
| C | CPU first | 51.792 ms | 0.062 ms | 91.060 ms | 65.045 ms | 44.427 ms | 39.716–47.183 ms |

The median of all 15 repeated warm bridge calls was 45.356 ms. Each call
includes command construction, dispatch, synchronization, and CPU reduction of
the per-thread row counts and `Int64` sums.

The single-thread SIMD CPU pass inside this diagnostic is a correctness oracle,
not the performance reference. It measured 347–383 ms. The established
eight-thread equivalent-work reference measured 79.495–79.570 ms, so the warm
direct-Metal kernel is approximately 1.75x faster. The copied Mojo GPU kernel
measured 59.211 ms in its warm series; direct MSL reduced that time by about
23%.

The 413-station fixture also passed exactly with 413 rows and fixed-point sum
151,304.

## Interpretation

Temperature parsing preserves useful warm GPU headroom after removing the
input copy. The 2.7x scan-only advantage narrows to 1.75x once four temperature
bytes are parsed at every newline, but it remains materially stronger than the
copied Mojo GPU result.

One-shot execution still loses. Context and pipeline creation took 49–55 ms,
and the first file-backed dispatch took 201–747 ms in GPU-first sessions. CPU
pre-touch reduced the first dispatch to 91 ms, but context plus dispatch was
still about 143 ms before counting the pre-touch itself.

## Next gate

The retained compact-rank station index passed exact correctness but measured a
146.835 ms combined warm median, slower than the established CPU references.
The gate therefore fails and aggregation remains stopped. Station evidence is
in `measurements_100m_station.md`.
