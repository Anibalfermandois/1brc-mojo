# Zero-copy `mmap` input for a Mojo Metal kernel

## Forum question

What is the supported way to let a Mojo kernel on Apple Silicon read an
existing file-backed `mmap` without first copying the entire mapping into a
`DeviceBuffer`?

I am experimenting with a Mojo implementation of 1BRC on an Apple M3 using:

```text
Mojo 1.0.0b3.dev2026073014 (86c799a2)
DeviceContext(api="metal")
```

The kernel only reads the input. The CPU maps the file with `mmap(PROT_READ,
MAP_SHARED)` and retains the mapping until after `DeviceContext.synchronize()`.

## Current Mojo path

The working implementation allocates a Metal-backed `DeviceBuffer` and copies
the whole mapping into it:

```mojo
var mapped = MappedFile(filename)
var ctx = DeviceContext(api="metal")

var data_buffer = ctx.enqueue_create_buffer[DType.uint8](mapped.size)
ctx.enqueue_copy(data_buffer, mapped.ptr)
ctx.synchronize()

ctx.enqueue_function(
    kernel,
    data_buffer,
    mapped.size,
    grid_dim=256,
    block_dim=256,
)
```

For a 1,379,614,933-byte input, the resident-data GPU newline scan takes about
23 ms, compared with about 61 ms for an eight-thread CPU SIMD scan. However,
the warm `mmap`-to-`DeviceBuffer` copy takes roughly 193-245 ms, so the copy
eliminates the kernel advantage.

These timings were collected while the computer remained in normal use. The
large difference between the copy and kernel is nevertheless consistent across
the measured runs.

## Desired path

The ideal shape is:

```text
file-backed mmap
        |
        | no full-file copy
        v
Metal shared buffer / GPU-visible pointer
        |
        v
Mojo kernel reads the bytes
```

At the Mojo source level, the tempting experiment is to pass the mapping's
`UnsafePointer` directly:

```mojo
ctx.enqueue_function(
    kernel,
    mapped.ptr,
    mapped.size,
    grid_dim=256,
    block_dim=256,
)
```

`UnsafePointer` implements `DevicePassable`, but I do not know whether that
means an arbitrary host pointer is valid for the Metal backend. The documented
GPU path maps a host-side `DeviceBuffer` to an `UnsafePointer` in the kernel;
that does not necessarily imply that a normal CPU virtual address is a valid
Metal buffer argument.

## Why this appears possible in Metal

Metal exposes
[`makeBuffer(bytesNoCopy:length:options:deallocator:)`](https://developer.apple.com/documentation/metal/mtldevice/makebuffer%28bytesnocopy%3Alength%3Aoptions%3Adeallocator%3A%29),
which wraps an existing contiguous, page-aligned VM region as an `MTLBuffer`.
An `mmap` starts on a page boundary, and the logical file length can remain a
separate kernel bound while the wrapped region length is rounded to a page
boundary.

The intended resource mode would be `MTLResourceStorageModeShared`. The mapping
and its backing file descriptor would remain alive until GPU completion. The
kernel never writes to the input or reads beyond the logical file size.

The documented Mojo
[`DeviceBuffer`](https://mojolang.org/docs/std/gpu/host/device_context/DeviceBuffer/)
API exposes allocation through `DeviceContext`, but I have not found a public
constructor that wraps an external `MTLBuffer` or an existing host allocation.

## Questions

1. On the Metal backend, is passing an `UnsafePointer` obtained from `mmap`
   directly to `enqueue_function()` supported? If not, what does
   `UnsafePointer: DevicePassable` guarantee on Metal?
2. Is there a supported Mojo or AsyncRT API for wrapping an existing
   `MTLBuffer`, or page-aligned host allocation, as a `DeviceBuffer`?
3. Does `DeviceBuffer.map_to_host()` provide a guaranteed shared/no-copy view
   on Apple Silicon, or is it allowed to allocate and copy?
4. Can Mojo expose the native `MTLDevice` or buffer handle associated with a
   `DeviceContext` so that `makeBuffer(bytesNoCopy:)` can interoperate with the
   same context?
5. If a read-only file mapping cannot be wrapped because Metal requires a
   mutable VM region, is a private read/write mapping (`MAP_PRIVATE`) the
   recommended solution when the GPU still performs reads only?
6. Is there another supported way to read a file directly into GPU-visible
   shared storage without an additional full-memory copy?

## Correctness and lifetime constraints

- The input is immutable for the complete kernel execution.
- The mapping remains alive until the command stream is synchronized.
- The Metal buffer length can be page-rounded, but the kernel receives the
  exact file length and bounds every read against it.
- GPU and CPU results are compared exactly before timing.
- Avoiding the copy is expected to remove duplicate memory traffic, not cold
  file faults or the cost of initially bringing file pages into RAM.

The main uncertainty is therefore not whether Apple Silicon has unified
physical memory. It is how Mojo's Metal backend requires externally owned
memory to be registered and encoded as a kernel argument.
