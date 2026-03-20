# 1BRC Mojo — Hot Path Optimizations

## SIMD Row Scanning (with `std.bit`)

The inner loop of `parse_chunk` uses 16-byte SIMD windows and the `count_trailing_zeros` hardware-accelerated function (from `std.bit`) to locate newlines in 1 cycle. This replaced the raw `llvm.cttz.i16` intrinsic, maintaining the high **Engine Peak** performance.

## Branchless Temperature Parsing (8-Byte Load)

Once a newline is found, the parser performs a single unaligned 8-byte load backwards. Bitwise arithmetic replaces conditionals for handling the sign and decimal point, keeping the instruction pipeline full.
