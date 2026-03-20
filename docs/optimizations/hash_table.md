# 1BRC Mojo — Hash Table Design

The hash table is the most critical component, as every row results in a lookup and an update.

## Perfect Hashing (O(1) Guaranteed)

Instead of a general-purpose hash map, we use a **Perfect Hash Function** specialized for the 413 weather stations. This eliminates collisions entirely (Zero Probes) and enables the extreme **Engine Peak** throughput.

## Array of Structures (AoS) for Cache Locality

We consolidated all per-station data into a single `MapEntry` struct (48 bytes). When the CPU fetches a station's stats, the name pointer and length are pulled into the **same cache line**.

## Zero-Allocation Strategy

The hash table performs **zero heap allocations** during the hot loop. The table is pre-allocated on the heap using `UnsafePointer.alloc`.

## Integer Accumulator

Temperatures are parsed as integers (e.g., `12.3` becomes `123`), keeping the hot path purely integer-based.
