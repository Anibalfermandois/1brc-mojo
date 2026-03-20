# 1BRC Mojo — GPU Investigation (Metal)

Can Apple Silicon's unified memory allow a Metal GPU kernel to parse faster?

**Conclusion: No. GPU is 7.3× slower end-to-end.**

## Key Bottlenecks

- **Data Upload:** Metal requires copies (~8 GB traffic for 4 GB file). CPU `mmap` is zero-cost.
- **Memory Access:** 1BRC is a low arithmetic intensity task (1.5 FLOPs/byte). CPUs excel at these memory-bound scans; GPUs excel at high-intensity compute (1000+ FLOPs/byte).

## Benchmark Results (300M rows, System Wall-Clock)

| Phase | CPU (`main.mojo`) | GPU (`gpu_main.mojo`) |
|---|---|---|
| Parallel parse | **486ms** | **4686ms** |
| Total | **~2467ms** | **~17939ms** |
