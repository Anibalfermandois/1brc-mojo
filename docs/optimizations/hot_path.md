# 1BRC Mojo — Hot Path Optimizations

## SIMD Row Scanning (with `std.bit`)

The inner loop of `parse_chunk` uses 16-byte SIMD windows and the `count_trailing_zeros` hardware-accelerated function (from `std.bit`) to locate newlines in 1 cycle. This replaced the raw `llvm.cttz.i16` intrinsic, maintaining the high **Engine Peak** performance.

Analysis mode records SIMD iterations, hit blocks, single- versus
multiple-newline blocks, vector rows, and scalar-tail rows. On the 100M input,
96.77% of vector blocks contain a newline and 80.15% of hit blocks contain
exactly one. The straightforward mask loop remains active: an isolated
peeled-first-newline path was performance-neutral.

The `reduce_or()` guard remains before SWAR mask packing. Removing it saves
three instructions on hit blocks in current Mojo 1.0 assembly, but its
controlled wall-clock result was neutral.

## Branchless Temperature Parsing (8-Byte Load)

Once a newline is found, the parser performs a single unaligned 8-byte load backwards. Bitwise arithmetic replaces conditionals for handling the sign and decimal point, keeping the instruction pipeline full.
