I ran into this while trying a GPU implementation of 1BRC on an M3. My input
is already memory-mapped, but the [documented Mojo
flow](https://docs.modular.com/mojo/manual/gpu/fundamentals/) appears to require
allocating a `DeviceBuffer` and copying the input into it:

```mojo
var input = ctx.enqueue_create_buffer[DType.uint8](size)
ctx.enqueue_copy(input, mmap_ptr)
```

Metal can wrap a suitable existing allocation without copying via
[`makeBuffer(bytesNoCopy:...)`](https://developer.apple.com/documentation/metal/mtldevice/1433382-newbufferwithbytesnocopy).
Is there a supported Mojo/AsyncRT way to do the equivalent for host memory?

If not, could `DeviceContext` expose something roughly like this?

```mojo
var input = ctx.wrap_external_buffer[DType.uint8](
    mmap_ptr, size, ownership=.borrowed
)
```

I found [#6145](https://github.com/modular/modular/issues/6145), now tracked
under the [Apple Silicon GPU epic
#5468](https://github.com/modular/modular/issues/5468), but that issue is about
passing an `UnsafePointer` directly to a kernel. I am asking whether Mojo could
provide an explicit, lifetime-safe way to register existing host memory as a
device buffer.
