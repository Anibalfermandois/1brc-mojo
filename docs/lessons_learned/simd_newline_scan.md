# Lesson Learned: SIMD Backward Newline Scan

## Implementation
We attempted to optimize the `DoubleBufferedStream` by replacing the scalar `find_last_newline` function with a SIMD-accelerated version. This function is used to find the boundary of the last full row in a 4MB buffer before parsing.

### Technical Details
The SIMD version used 16-byte chunks, a SIMD comparison against `ASCII_LF` (10), and a forward-mapping gather trick (`0x0102040810204080`) to identify the highest set bit in the resulting mask.

```mojo
# SIMD backward scan snippet
while i >= width:
    var chunk = ptr.load[width=width](i - width)
    var mask = chunk.eq(nl_vec)
    if mask.reduce_or():
        var bytes = mask.cast[DType.uint8]() & 1
        var u64 = bitcast[DType.uint64, 2](bytes)
        var res0 = (u64[0] * 0x0102040810204080) >> 56
        var res1 = (u64[1] * 0x0102040810204080) >> 56
        var final_mask = Int(res0) | (Int(res1) << 8)
        var bit_idx = 31 - count_leading_zeros(UInt32(final_mask))
        return i - width + Int(bit_idx)
    i -= width
```

## Performance Analysis
Benchmarks on the 1B dataset showed no measurable improvement:
- **Baseline (Scalar)**: ~4321ms median.
- **SIMD Optimized**: ~4458ms median.

### Why it failed to provide gains
The `find_last_newline` function is called only once per 4MB block. 
For a 13GB file, this is only ~3,300 calls total. 
Even if the scalar scan takes ~10-20ms in aggregate (which is generous), it is negligible compared to the 4,000ms+ total execution time. 

## Conclusion
The complexity of the SIMD code outweighs the performance benefit in this specific part of the I/O pipeline. We have reverted to the simpler scalar implementation to maintain codebase readability.
