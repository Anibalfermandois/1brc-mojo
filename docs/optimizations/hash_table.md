# 1BRC Mojo — Hash Table Design

The hash table is the most critical component, as every row results in a lookup and an update.

## Perfect Hashing (O(1) Guaranteed)

Instead of a general-purpose hash map, we use a **Perfect Hash Function** specialized for the 413 weather stations. This eliminates collisions entirely (Zero Probes) and enables the extreme **Engine Peak** throughput.

## Array of Structures (AoS)

Each logical `MapEntry` contains 32 bytes of statistics and name metadata and is
declared with `@align(64)`. Thread-local ownership means alignment is not
required to prevent false sharing. A 2026-07-30 `A-B-B-A` experiment isolated
the annotation: the reliable closing pair differed by only −0.44% wall and
−2.82% parse for the unaligned variant, below the 5% threshold. Alignment
therefore remains as the neutral incumbent rather than a demonstrated
optimization.

## Zero-Allocation Strategy

The hash table performs **zero heap allocations** during the hot loop. The table is pre-allocated on the heap using `UnsafePointer.alloc`.

Thread maps merge by perfect-hash slot. Output names come from the generated
413-station table, so reusable streaming-buffer pointers are never dereferenced
after parsing.

## Integer Accumulator

Temperatures are parsed as integers (e.g., `12.3` becomes `123`), keeping the
hot path purely integer-based. `min` and `max` use `Int16`, `count` uses
`Int32`, and `sum` uses `Int64`. Expanding all four fields to native `Int`
preserved the 64-byte entry stride but made the closing comparison 0.79% slower
wall and 5.01% slower parse, so the compact representation remains active.
