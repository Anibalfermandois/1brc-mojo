# Metal mmap zero-copy station-index gate

## Result

The direct-Metal compact-rank station index is exact but does not beat the CPU
reference materially. Aggregation remains stopped.

Every retained packed-load dispatch returned:

- rows: 99,999,387;
- fixed-point temperature sum: 17,828,649,656;
- dense-ID sum: 20,600,838,346;
- squared dense-ID sum: 5,665,224,523,728; and
- invalid stations: 0.

The reduced semantic fixture containing `Palm Springs`, `Alice Springs`, and
`Wau` also passed with 3 rows, temperature sum 350, dense-ID sum 994, squared
dense-ID sum 339,754, and zero invalid stations.

## Environment

- Mojo: `1.0.0b3.dev2026073014 (86c799a2)`
- CPU/GPU: Apple M3
- Input: 1,379,614,933 bytes
- Grid: 256 blocks of 256 threads
- Process priority: `nice -n 10`
- Machine condition: normal concurrent workstation use

## Retained packed-load measurements

| Session | Context compile | No-copy wrap | Host table setup | Metal table copy | First dispatch | Warm median | Warm range |
|---|---:|---:|---:|---:|---:|---:|---:|
| A | 48.699 ms | 0.079 ms | 2.756 ms | 0.008 ms | 269.707 ms | 149.184 ms | 144.480–151.932 ms |
| B | 53.955 ms | 0.061 ms | 2.710 ms | 0.013 ms | 268.228 ms | 145.418 ms | 143.232–168.108 ms |

The combined ten-sample warm median was 146.835 ms. The established parallel
CPU station-index references were 135.773 ms in the faster paired series,
145.157 ms in a later repeat, and 140.796 ms in post-change verification. The
direct-Metal result is 1–8% slower across those references and does not satisfy
the material-win gate.

The CPU pass inside this diagnostic is a single-thread correctness oracle; its
488–504 ms timings are not the performance comparison.

## Variants

| Variant | Warm result | Decision |
|---|---:|---|
| Eight scalar suffix-byte loads | 344.242 ms median | Rejected |
| Two packed 4-byte suffix loads | 146.835 ms combined median | Retained baseline, gate failed |
| One unaligned 64-bit suffix load | Incorrect on reduced fixture | Rejected |

Two packed loads recovered 2.31x over scalar reconstruction. A single unaligned
`ulong` pointer load is not valid for arbitrary station-suffix addresses in MSL;
the reduced fixture produced one invalid station. The Palm/Alice collision also
requires 32-bit byte addressing within the station kernel's explicit
4.2-billion-byte input limit; a `ulong - constant` byte access returned
robust-access zero for this branch.

## Decision

Do not implement GPU aggregation. The no-copy scan and temperature gates win
when warm, but station indexing consumes the remaining lead before aggregation
begins. Runtime MSL precompilation could reduce the 49–54 ms context cost, but
cannot change the failed 146.835 ms warm station gate.
