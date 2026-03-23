# 1BRC Mojo: IR & ASM Analysis Report

This report analyzes the compiled output of the core components: `parse_chunk`, `parse_row`, and `update_or_insert`. The goal is to identify instruction-level inefficiencies and compiler behaviors that impact performance.

## Summary of Findings

1.  **SIMD Loop Overhead**: The conversion of SIMD masks to bitmasks in `parse_chunk` is a heavy sequence (13+ NEON instructions).
2.  **Inlining Efficacy**: The compiler successfully inlines the entire parsing and map update logic into the SIMD loop, which is efficient but creates large loop bodies.
3.  **Redundant Masking**: In the hash calculation, there are some masking operations (`& 0xFFFFFF`) that might be redundant if the input data is handled differently.
4.  **Temperature Parsing**: The bit-math for temperature parsing is quite tight, using efficient `umaddl` and `csel` instructions.

---

## Component Analysis

### 1. `parse_chunk` (SIMD Loop)

The hottest part of the engine is the SIMD loop that locates `\n` characters.

#### ASM Observations:
- **Newline Detection**: Uses `cmeq.16b` (vector compare equal) followed by `umaxv.16b` (vector max across lanes) to quickly check if *any* newline exists in 16 bytes. This is optimal for the `likely()` path.
- **Bitmask Extraction**: To find the exact index of newlines, the code converts the boolean mask to a 16-bit integer.
  ```asm
  sshll2.8h   v4, v3, #0
  and.16b     v4, v4, v1
  ushll.8h    v3, v3, #0
  and.16b     v3, v3, v2
  orr.16b     v3, v3, v4
  ... (13 instructions total) ...
  fmov        w4, s3
  ```
  **Inefficiency**: This 13-instruction sequence is the result of [(mask.cast[DType.uint16]() * u16_powers).reduce_add()](file:///Users/anibalfermandois/techProjects/mojo/1brc/entrypoints/bench.sh#40-43). On ARM NEON, this can often be done more efficiently with `shrn` (shift right and narrow) or a dot product.

### 2. `parse_row` & Temperature Parsing

Analyzed as inlined code within `parse_chunk`.

#### ASM Observations:
- **Load Strategy**: It loads the last 8 bytes of a row using `ldur x9, [x8, #-8]`. This is clever as it captures the temperature regardless of its exact alignment.
- **Parsing Math**:
  ```asm
  ubfx    x14, x9, #40, #8
  mov     w15, #10
  umaddl  x13, w14, w15, x13
  ```
  The compiler uses `umaddl` (unsigned multiply-add long) to combine decimal digits. It correctly handles the fixed-point math (`sum = tens * 100 + units * 10 + frac`).
- **Sign Handling**: Uses `ccmp` and `csel` to apply the sign without branching. This is highly efficient for the random distribution of positive/negative temperatures.

### 3. Hash Map Update (`update_or_insert`)

#### LLVM IR Highlights:
```llvm
%41 = shl i32 %20, 8
%42 = zext i32 %41 to i64
%43 = shl nuw nsw i64 %24, 32
%44 = or disjoint i64 %43, %42
%45 = or i64 %44, %16
%46 = mul i64 %45, 7980373453494448537
```
- **Hash Input**: The hash effectively uses the first 4 bytes of the station name (%20), the character at `length-3` (%24), and the `length` itself (%16).
- **Multiplication**: The 64-bit multiplication and shift are standard and fast.
- **Map Slot Access**:
  ```asm
  ldr     x11, [x0]
  mov     w13, #48
  umaddl  x10, w10, w13, x11
  ```
  The slot size is **48 bytes**. The `umaddl` here computes `map_base + (index * 48)`. This is a single cycle on M-series chips.

---

## Potential Optimizations to Explore

1.  **NEON "Movemask"**: Replace the `reduce_add` with a sequence that compiles to `shrn` or a more efficient bit-packing on ARM.
2.  **Loop Pipelining/Unrolling**: While the compiler unrolls slightly, manual 4x unrolling (which I've started testing) can hide memory latency of the `ldur` loads.
3.  **Speculative Hashing**: Since names are usually longer than 4 bytes, we could tentatively load 8 bytes for the hash and name compare, avoiding the separate `ptr[length-3]` load if it happens frequently.
