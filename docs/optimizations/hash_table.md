# 1BRC Mojo — Hash Table Design

The hash table is the most critical component, as every row results in a lookup and an update.

## Perfect Hashing (O(1) Guaranteed)

Instead of a general-purpose hash map, we use a **Perfect Hash Function** specialized for the 413 weather stations. This eliminates collisions entirely (Zero Probes) and enables the extreme **Engine Peak** throughput.

## Array of Structures (AoS)

Each logical `MapEntry` contains 32 bytes of statistics and name metadata and is
declared with `@align(64)`. On the current compiler this gives the allocation a
64-byte-aligned base while array elements still use a 32-byte stride. Because
maps are thread-local, adjacent entries sharing a cache line does not create
inter-thread false sharing. A 2026-07-30 `A-B-B-A` experiment isolated the
annotation: the reliable closing pair differed by only −0.44% wall and −2.82%
parse for the unaligned variant, below the 5% threshold. Base alignment remains
a neutral incumbent rather than a demonstrated optimization.

## Zero-Allocation Strategy

The hash table performs **zero heap allocations** during the hot loop. The table is pre-allocated on the heap using `UnsafePointer.alloc`.

Thread maps merge by perfect-hash slot. Output names come from the generated
413-station table, so reusable streaming-buffer pointers are never dereferenced
after parsing.

## Integer Accumulator

Temperatures are parsed as integers (e.g., `12.3` becomes `123`), keeping the
hot path purely integer-based. `min` and `max` use `Int16`, `count` uses
`Int32`, and `sum` uses `Int64`. Expanding all four fields to native `Int`
also changed the entry stride from 32 to 48 bytes and made the closing
comparison 0.79% slower wall and 5.01% slower parse. The compact representation
remains active; that experiment did not isolate arithmetic width from layout.
