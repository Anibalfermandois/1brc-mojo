"""gpu_main.mojo — GPU-accelerated 1BRC investigation prototype

Architecture:
  One GPU thread per file chunk (mirrors the CPU parallelize model in main.mojo).
  Each GPU thread sequentially scans its chunk for rows and accumulates per-station
  stats into its own private section of a global result buffer. No shared memory
  and no atomics are needed because threads have non-overlapping result sections.
  The CPU reads the result buffer back and merges with PerfectStationMap.

Key investigation question:
  Does GPU thread parsing throughput x memory bandwidth advantage offset the
  data-upload cost vs the CPU-only path in main.mojo?

Design notes:
  - N_CHUNKS = 256 matches current CPU thread count on a 10-core M-series
  - Result buffer layout: [N_CHUNKS][GPU_CAPACITY][ENTRY_WORDS] of Int64
  - Entry layout: [0]=min, [1]=max, [2]=sum, [3]=count, [4]=name_offset, [5]=name_len
  - MAX_FILE_BYTES sets the compile-time LayoutTensor size; actual device buffer
    is allocated to 'size' bytes. Kernel always bounds-checks via chunk_end.
  - Name resolution on CPU uses the original mmap ptr + name_offset stored in the
    result -- avoids the MutAnyOrigin/MutExternalOrigin mismatch.

Known limitations (deliberate -- first investigation baseline):
  - block_dim=1 underutilises GPU; gives per-thread throughput baseline
  - No SIMD newline scanning on GPU (byte-by-byte only)
  - Max file size is compile-time bounded by MAX_FILE_BYTES
"""

from std.sys import argv
from std.sys import has_accelerator
from std.gpu import global_idx
from std.gpu.host import DeviceContext, DeviceBuffer
from std.memory import UnsafePointer
from std.ffi import external_call
from layout import Layout, LayoutTensor
from perfect_hashmap import PerfectStationMap, StationStats, MapEntry
from metrics import EmptyMapMetrics
from mmap import MappedFile, MADV_WILLNEED

# Compile-time constants
comptime MAX_FILE_BYTES: Int = 4_200_000_000  # 4.1 GB; increase for larger files
comptime N_CHUNKS: Int = 256                  # GPU worker threads
comptime GPU_CAPACITY: Int = 16384            # hash table capacity (matches CPU)
comptime GPU_MULTIPLIER = UInt64(11164934581231786391)
comptime GPU_SHIFT = UInt64(50)
comptime ENTRY_WORDS: Int = 6                 # Int64 words per hash entry
comptime RESULT_SIZE: Int = N_CHUNKS * GPU_CAPACITY * ENTRY_WORDS

# Result entry layout (each field is one Int64 word):
#   [0]=min  [1]=max  [2]=sum  [3]=count  [4]=name_offset  [5]=name_len

comptime data_layout   = Layout.row_major(MAX_FILE_BYTES)
comptime chunks_layout = Layout.row_major(N_CHUNKS + 1)
comptime result_layout = Layout.row_major(RESULT_SIZE)


def gpu_parse_kernel(
    data: LayoutTensor[DType.uint8, data_layout, MutAnyOrigin],
    chunk_starts: LayoutTensor[DType.int64, chunks_layout, MutAnyOrigin],
    result: LayoutTensor[DType.int64, result_layout, MutAnyOrigin],
):
    """One GPU thread per file chunk. Parses rows sequentially, no atomics."""
    var tid = Int(global_idx.x)
    var chunk_start = Int(rebind[Scalar[DType.int64]](chunk_starts[tid]))
    var chunk_end   = Int(rebind[Scalar[DType.int64]](chunk_starts[tid + 1]))

    var res_base = tid * GPU_CAPACITY * ENTRY_WORDS

    # Zero-initialise this thread's result section.
    for j in range(GPU_CAPACITY * ENTRY_WORDS):
        result[res_base + j] = rebind[result.element_type](Int64(0))

    var row_start = chunk_start
    var i = chunk_start

    while i < chunk_end:
        # Find end-of-row (byte-by-byte; no SIMD in this baseline kernel).
        while i < chunk_end:
            if rebind[Scalar[DType.uint8]](data[i]) == UInt8(10):
                break
            i += 1
        if i >= chunk_end:
            break
        var nl = i
        i += 1

        # Shortest valid row is "X;9.9\n" (7 bytes).
        if nl - row_start < 7:
            row_start = i
            continue

        # Build a little-endian UInt64 from 8 bytes ending at nl:
        #   byte at (nl-8+k) occupies bits [k*8 .. k*8+7]
        # So (chunk8 >> 56) & 0xFF == byte at nl-1, matching parse_row on CPU.
        var chunk8 = UInt64(0)
        comptime for k in range(8):
            chunk8 |= (
                UInt64(rebind[Scalar[DType.uint8]](data[nl - 8 + k]))
                << UInt64(k * 8)
            )

        var c_frac  = Int((chunk8 >> 56) & 0xFF) - 48
        var c_units = Int((chunk8 >> 40) & 0xFF) - 48
        var c4      = Int((chunk8 >> 32) & 0xFF)
        var c5      = Int((chunk8 >> 24) & 0xFF)

        var c5_is_semi = Int(c5 == 59)
        var c4_is_semi = Int(c4 == 59)
        var offset   = 6 - c5_is_semi - (c4_is_semi * 2)
        var name_len = nl - offset - row_start

        if name_len < 2 or name_len > 100:
            row_start = i
            continue

        var c4_val   = c4 & 0x0F
        var has_tens = Int(c4_val <= 9)
        var is_neg   = Int(c4 == 45) | Int(c5 == 45)
        var temp_val = (c4_val * has_tens * 100) + (c_units * 10) + c_frac
        temp_val *= (1 - is_neg * 2)

        # Hash key -- identical extraction to PerfectStationMap.update_or_insert.
        var k = UInt64(name_len)
        k |= UInt64(rebind[Scalar[DType.uint8]](data[row_start])) << 8
        k |= UInt64(rebind[Scalar[DType.uint8]](data[row_start + (name_len >> 1)])) << 16
        k |= UInt64(rebind[Scalar[DType.uint8]](data[row_start + name_len - 1])) << 24
        k |= UInt64(rebind[Scalar[DType.uint8]](data[row_start + 1])) << 32
        k |= UInt64(rebind[Scalar[DType.uint8]](data[row_start + name_len - 2])) << 40
        var idx = Int((k * GPU_MULTIPLIER) >> GPU_SHIFT)

        # Update result entry (no atomics -- single thread owns this section).
        var e     = res_base + idx * ENTRY_WORDS
        var count = rebind[Scalar[DType.int64]](result[e + 3])

        if count == Int64(0):
            result[e + 0] = rebind[result.element_type](Int64(temp_val))
            result[e + 1] = rebind[result.element_type](Int64(temp_val))
            result[e + 2] = rebind[result.element_type](Int64(temp_val))
            result[e + 3] = rebind[result.element_type](Int64(1))
            result[e + 4] = rebind[result.element_type](Int64(row_start))
            result[e + 5] = rebind[result.element_type](Int64(name_len))
        else:
            var cur_min = rebind[Scalar[DType.int64]](result[e + 0])
            var cur_max = rebind[Scalar[DType.int64]](result[e + 1])
            var cur_sum = rebind[Scalar[DType.int64]](result[e + 2])
            if Int64(temp_val) < cur_min:
                result[e + 0] = rebind[result.element_type](Int64(temp_val))
            if Int64(temp_val) > cur_max:
                result[e + 1] = rebind[result.element_type](Int64(temp_val))
            result[e + 2] = rebind[result.element_type](cur_sum + Int64(temp_val))
            result[e + 3] = rebind[result.element_type](count + Int64(1))

        row_start = i


def main() raises:
    comptime if not has_accelerator():
        print("No GPU found. gpu_main.mojo requires a GPU.")
        return

    var filename = "measurements_300m.txt"
    if len(argv()) > 1:
        filename = argv()[1]

    print("GPU 1BRC:", filename)
    print("N_CHUNKS =", N_CHUNKS, "  GPU_CAPACITY =", GPU_CAPACITY)

    var mapped = MappedFile(filename)
    var size   = mapped.size
    if size > MAX_FILE_BYTES:
        print("ERROR: file size", size, "exceeds MAX_FILE_BYTES =", MAX_FILE_BYTES)
        print("Recompile with a larger MAX_FILE_BYTES constant.")
        mapped.close()
        return
    mapped.advise(MADV_WILLNEED)

    # Chunk boundaries (same newline-retreat strategy as main.mojo).
    var chunk_size = size // N_CHUNKS
    var cpu_chunks = List[Int64](capacity=N_CHUNKS + 1)
    cpu_chunks.append(Int64(0))
    for ci in range(1, N_CHUNKS):
        var guess = ci * chunk_size
        while guess > 0 and mapped.ptr[guess - 1] != 10:
            guess -= 1
        cpu_chunks.append(Int64(guess))
    cpu_chunks.append(Int64(size))

    var ctx = DeviceContext()

    # Upload file data to GPU.
    # Metal requires buffers to be Metal-managed; plain mmap pointers are not
    # valid. We allocate a Metal-compatible host buffer and memcpy from mmap.
    # On Apple Silicon (unified memory) this copies virtual-address mappings
    # within the same physical DRAM -- typically ~50 ms for 4 GB.
    var host_data_buf = ctx.enqueue_create_host_buffer[DType.uint8](size)
    ctx.synchronize()
    _ = external_call["memcpy", NoneType](
        host_data_buf.unsafe_ptr().bitcast[NoneType](),
        mapped.ptr.bitcast[NoneType](),
        size,
    )
    var dev_data_buf = ctx.enqueue_create_buffer[DType.uint8](size)
    ctx.enqueue_copy(dev_data_buf, host_data_buf)

    var host_chunks_buf = ctx.enqueue_create_host_buffer[DType.int64](N_CHUNKS + 1)
    ctx.synchronize()
    var hcp = host_chunks_buf.unsafe_ptr()
    for ci in range(N_CHUNKS + 1):
        hcp[ci] = cpu_chunks[ci]
    var dev_chunks_buf = ctx.enqueue_create_buffer[DType.int64](N_CHUNKS + 1)
    ctx.enqueue_copy(dev_chunks_buf, host_chunks_buf)

    var dev_result_buf = ctx.enqueue_create_buffer[DType.int64](RESULT_SIZE)
    ctx.synchronize()

    var dev_data   = LayoutTensor[DType.uint8, data_layout](dev_data_buf)
    var dev_chunks = LayoutTensor[DType.int64, chunks_layout](dev_chunks_buf)
    var dev_result = LayoutTensor[DType.int64, result_layout](dev_result_buf)

    # grid_dim=N_CHUNKS, block_dim=1: one thread per chunk.
    # Deliberate underutilisation to measure per-thread GPU throughput baseline.
    ctx.enqueue_function[gpu_parse_kernel, gpu_parse_kernel](
        dev_data,
        dev_chunks,
        dev_result,
        grid_dim=N_CHUNKS,
        block_dim=1,
    )
    ctx.synchronize()

    # Merge: read result buffer, resolve names via original mmap ptr + name_offset.
    # Using mapped.ptr (MutExternalOrigin) avoids any unsafe origin casting.
    var final_map = PerfectStationMap[MAP_TRACKER=EmptyMapMetrics]()

    with dev_result_buf.map_to_host() as host_result:
        var result_view = LayoutTensor[DType.int64, result_layout](host_result)
        for chunk_id in range(N_CHUNKS):
            var res_base = chunk_id * GPU_CAPACITY * ENTRY_WORDS
            for slot in range(GPU_CAPACITY):
                var e     = res_base + slot * ENTRY_WORDS
                var count = Int(rebind[Scalar[DType.int64]](result_view[e + 3]))
                if count == 0:
                    continue

                var name_off = Int(rebind[Scalar[DType.int64]](result_view[e + 4]))
                var name_len = Int(rebind[Scalar[DType.int64]](result_view[e + 5]))
                var name_ptr = mapped.ptr + name_off

                var stats = StationStats(
                    Int(rebind[Scalar[DType.int64]](result_view[e + 0]))
                )
                stats.max   = Int(rebind[Scalar[DType.int64]](result_view[e + 1]))
                stats.sum   = Int(rebind[Scalar[DType.int64]](result_view[e + 2]))
                stats.count = count

                final_map.update_from_stats(name_ptr, name_len, stats)

    final_map.print_sorted()
    mapped.close()
