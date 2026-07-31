# Metal mmap zero-copy scan proof

## Result

Metal accepted the Mojo-created read-only `mmap` through
`newBufferWithBytesNoCopy`. The bridge counted exactly 99,999,387 newlines in
the 1,379,614,933-byte 100M input on every dispatch without allocating or
copying an input buffer.

- Mojo: `1.0.0b3.dev2026073014 (86c799a2)`
- CPU/GPU: Apple M3
- VM page size: 16,384 bytes
- Metal buffer length: 1,379,631,104 bytes
- Process priority: `nice -n 10`
- Machine condition: normal concurrent workstation use

## Measurements

The GPU-first sessions wrapped the mapping and dispatched before the CPU
correctness scan. The CPU-first session scanned the file before the first Metal
dispatch to separate file residency from Metal's first access to the VM region.

| Session | Order | Context and runtime MSL compile | No-copy wrap | First dispatch wall | First dispatch GPU | Warm wall median | Warm wall range |
|---|---|---:|---:|---:|---:|---:|---:|
| A | GPU first | 51.632 ms | 0.057 ms | 671.430 ms | 27.126 ms | 22.002 ms | 21.373–24.742 ms |
| B | GPU first | 43.808 ms | 0.073 ms | 186.194 ms | 49.654 ms | 22.574 ms | 21.384–23.341 ms |
| C | CPU first | 57.254 ms | 0.085 ms | 70.954 ms | 43.298 ms | 26.039 ms | 21.618–28.492 ms |
| D | GPU first | 45.407 ms | 0.079 ms | 723.192 ms | 44.896 ms | 23.046 ms | 21.777–26.520 ms |

The median of all 20 repeated warm bridge calls was 22.729 ms. Each call
includes command construction, dispatch, synchronization, and CPU reduction of
65,536 private counters. It excludes context creation and buffer wrapping.

The fixture test also passed exactly: 413 newlines in `docs/stations413.txt`.

## Interpretation

The no-copy primitive passes. Wrapping 1.38 GB took less than 0.1 ms, compared
with 193–245 ms for the warm copied `DeviceBuffer` path. Repeated scans preserve
the resident-buffer kernel's roughly 22–24 ms performance.

Zero-copy does not remove first access costs. The first full dispatch against a
new file-backed Metal buffer varied from 70.954 to 723.192 ms. CPU pre-touch
reduced that wall time but did not reduce it to the repeated-dispatch range.
Metal command timing also omitted much of the first-dispatch wall delay, which
is consistent with VM/page residency and command scheduling outside measured
GPU execution. Normal PC activity and shared-memory pressure remain part of the
test condition.

This bridge runs an MSL kernel. The public Mojo `DeviceBuffer` API still cannot
adopt the external `MTLBuffer`, so this result does not remove staging from the
existing Mojo-compiled GPU kernels.

## Next gate

The exact temperature-only kernel passed with a 45.356 ms warm median and 1.75x
advantage over the parallel CPU temperature reference. The retained direct-Metal
station index then measured a 146.835 ms combined warm median, slower than the
established CPU references, so aggregation remains stopped. Temperature and
station evidence is in `measurements_100m_temperature.md` and
`measurements_100m_station.md`.
