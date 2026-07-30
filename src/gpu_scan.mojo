"""Staged GPU investigation: resident-data scanning and temperature parsing.

This executable answers two bounded questions before station aggregation:
can a conventionally occupied Metal kernel scan the input materially faster
than the parallel CPU SIMD scanner, and how much of that lead remains after
fixed-point temperature parsing?

The GPU kernel uses 256-thread blocks. Adjacent lanes read adjacent bytes, and
each lane advances by the total grid width. Every lane writes one private
counter, avoiding atomics and shared-memory contention in this first gate.

Input preparation, CPU time, GPU kernel time, and result readback are reported
separately. The GPU input is staged through a DeviceBuffer; zero-copy
mmap/Metal interop is intentionally a separate experiment.
"""

from std.bit import count_trailing_zeros
from std.ffi import external_call
from std.gpu import global_idx
from std.gpu.host import DeviceContext
from std.memory import UnsafePointer, alloc, bitcast
from std.sys import argv, has_accelerator
from std.sys.info import num_logical_cores
from std.time import perf_counter_ns

from IO.mmap import MappedFile


comptime MAX_FILE_BYTES = 4_200_000_000
comptime BLOCK_SIZE = 256
comptime NUM_BLOCKS = 256
comptime NUM_GPU_THREADS = BLOCK_SIZE * NUM_BLOCKS
comptime BENCH_PAIRS = 5

def gpu_count_newlines(
    data: UnsafePointer[UInt8, MutAnyOrigin],
    counts: UnsafePointer[Int64, MutAnyOrigin],
    size: Int,
):
    """Count newlines with coalesced grid-stride reads and private counters."""
    var tid = Int(global_idx.x)
    var count = Int64(0)
    var i = tid

    while i < size:
        count += Int64(data[i] == UInt8(10))
        i += NUM_GPU_THREADS

    counts[tid] = count


def gpu_parse_temperatures(
    data: UnsafePointer[UInt8, MutAnyOrigin],
    counts: UnsafePointer[Int64, MutAnyOrigin],
    sums: UnsafePointer[Int64, MutAnyOrigin],
    size: Int,
):
    """Parse the fixed-point temperature at each newline, without aggregation."""
    var tid = Int(global_idx.x)
    var count = Int64(0)
    var total = Int64(0)
    var i = tid

    while i < size:
        if data[i] == UInt8(10):
            # Valid 1BRC rows place the earliest newline at byte seven. Read
            # only the four temperature bytes used by the CPU parser, avoiding
            # the first-row left overread of a blanket backward 64-bit load.
            var c_frac = Int(data[i - 1] & 0x0F)
            var c_units = Int(data[i - 3] & 0x0F)
            var c4 = Int(data[i - 4])
            var c5 = Int(data[i - 5])
            var c4_val = c4 & 0x0F
            var has_tens = Int(c4_val <= 9)
            var is_neg = Int(c4 == 45) | Int(c5 == 45)
            var temp = (
                (c4_val * has_tens * 100) + (c_units * 10) + c_frac
            )
            temp *= 1 - is_neg * 2
            total += Int64(temp)
            count += 1
        i += NUM_GPU_THREADS

    counts[tid] = count
    sums[tid] = total


@always_inline
def count_newlines_simd(
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin], size: Int
) -> Int:
    """Count newlines with the production parser's 16-byte SIMD/SWAR mask."""
    comptime width = 16
    comptime nl_vec = SIMD[DType.uint8, width](10)
    var count = 0
    var i = 0

    while i + width <= size:
        var chunk = ptr.load[width=width](i)
        var mask = chunk.eq(nl_vec)
        if mask.reduce_or():
            var bytes = mask.cast[DType.uint8]() & 1
            var u64 = bitcast[DType.uint64, 2](bytes)
            var res0 = (u64[0] * 0x0102040810204080) >> 56
            var res1 = (u64[1] * 0x0102040810204080) >> 56
            var final_mask = Int(res0) | (Int(res1) << 8)
            while final_mask != 0:
                count += 1
                final_mask &= final_mask - 1
        i += width

    while i < size:
        count += Int(ptr[i] == 10)
        i += 1

    return count


@always_inline
def parse_temperatures_simd(
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin], size: Int
) -> Tuple[Int, Int64]:
    """Return row count and temperature sum using the CPU SIMD newline mask."""
    comptime width = 16
    comptime nl_vec = SIMD[DType.uint8, width](10)
    var count = 0
    var total = Int64(0)
    var i = 0

    while i + width <= size:
        var chunk = ptr.load[width=width](i)
        var mask = chunk.eq(nl_vec)
        if mask.reduce_or():
            var bytes = mask.cast[DType.uint8]() & 1
            var u64 = bitcast[DType.uint64, 2](bytes)
            var res0 = (u64[0] * 0x0102040810204080) >> 56
            var res1 = (u64[1] * 0x0102040810204080) >> 56
            var final_mask = Int(res0) | (Int(res1) << 8)
            while final_mask != 0:
                var nl = i + Int(count_trailing_zeros(final_mask))
                var c_frac = Int(ptr[nl - 1] & 0x0F)
                var c_units = Int(ptr[nl - 3] & 0x0F)
                var c4 = Int(ptr[nl - 4])
                var c5 = Int(ptr[nl - 5])
                var c4_val = c4 & 0x0F
                var has_tens = Int(c4_val <= 9)
                var is_neg = Int(c4 == 45) | Int(c5 == 45)
                var temp = (
                    (c4_val * has_tens * 100)
                    + (c_units * 10)
                    + c_frac
                )
                temp *= 1 - is_neg * 2
                total += Int64(temp)
                count += 1
                final_mask &= final_mask - 1
        i += width

    while i < size:
        if ptr[i] == 10:
            var c_frac = Int(ptr[i - 1] & 0x0F)
            var c_units = Int(ptr[i - 3] & 0x0F)
            var c4 = Int(ptr[i - 4])
            var c5 = Int(ptr[i - 5])
            var c4_val = c4 & 0x0F
            var has_tens = Int(c4_val <= 9)
            var is_neg = Int(c4 == 45) | Int(c5 == 45)
            var temp = (
                (c4_val * has_tens * 100) + (c_units * 10) + c_frac
            )
            temp *= 1 - is_neg * 2
            total += Int64(temp)
            count += 1
        i += 1

    return count, total


def run_cpu_scan(
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    size: Int,
    counts_ptr: UnsafePointer[Int, MutUntrackedOrigin],
    num_threads: Int,
) raises -> Int:
    """Run the SIMD scanner over equal byte ranges on the CPU."""
    @parameter
    def process_chunk(tid: Int):
        var start = (size * tid) // num_threads
        var end = (size * (tid + 1)) // num_threads
        counts_ptr[tid] = count_newlines_simd(ptr + start, end - start)

    def process_chunk_unified(tid: Int):
        process_chunk(tid)

    var cpu_ctx = DeviceContext(api="cpu")
    cpu_ctx.enqueue_cpu_range(process_chunk_unified, count=num_threads)
    cpu_ctx.synchronize()

    var total = 0
    for tid in range(num_threads):
        total += counts_ptr[tid]
    return total


def run_cpu_temperature_parse(
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    size: Int,
    counts_ptr: UnsafePointer[Int, MutUntrackedOrigin],
    sums_ptr: UnsafePointer[Int64, MutUntrackedOrigin],
    num_threads: Int,
) raises -> Tuple[Int, Int64]:
    """Parse temperatures over equal byte ranges on the CPU."""
    @parameter
    def process_chunk(tid: Int):
        var start = (size * tid) // num_threads
        var end = (size * (tid + 1)) // num_threads
        var result = parse_temperatures_simd(ptr + start, end - start)
        counts_ptr[tid] = result[0]
        sums_ptr[tid] = result[1]

    def process_chunk_unified(tid: Int):
        process_chunk(tid)

    var cpu_ctx = DeviceContext(api="cpu")
    cpu_ctx.enqueue_cpu_range(process_chunk_unified, count=num_threads)
    cpu_ctx.synchronize()

    var total_count = 0
    var total_sum = Int64(0)
    for tid in range(num_threads):
        total_count += counts_ptr[tid]
        total_sum += sums_ptr[tid]
    return total_count, total_sum


def main() raises:
    comptime if not has_accelerator():
        print("ERROR: no compatible GPU found")
        return

    var filename = "measurements_100m.txt"
    if len(argv()) > 1:
        filename = argv()[1]

    var mapped = MappedFile(filename)
    var size = mapped.size
    if size <= 0 or size > MAX_FILE_BYTES:
        print(
            "ERROR: input size must be between 1 and ",
            MAX_FILE_BYTES,
            " bytes; got ",
            size,
        )
        mapped.close()
        return

    var num_cpu_threads = num_logical_cores()
    var cpu_counts = alloc[Int](num_cpu_threads)
    var cpu_sums = alloc[Int64](num_cpu_threads)

    var ctx = DeviceContext(api="metal")
    print("GPU device:", ctx.name())
    print("Input bytes:", size)
    print("CPU threads:", num_cpu_threads)
    print("GPU launch:", NUM_BLOCKS, "blocks x", BLOCK_SIZE, "threads")

    # The current high-level path copies the mmap into a Metal DeviceBuffer.
    # Time it explicitly so kernel-only results cannot hide staging overhead.
    var stage_start = perf_counter_ns()
    var data_buffer = ctx.enqueue_create_buffer[DType.uint8](size)
    ctx.enqueue_copy(data_buffer, mapped.ptr)
    ctx.synchronize()
    var stage_end = perf_counter_ns()

    var counts_buffer = ctx.enqueue_create_buffer[DType.int64](
        NUM_GPU_THREADS
    )
    var sums_buffer = ctx.enqueue_create_buffer[DType.int64](NUM_GPU_THREADS)
    var host_counts = ctx.enqueue_create_host_buffer[DType.int64](
        NUM_GPU_THREADS
    )
    var host_sums = ctx.enqueue_create_host_buffer[DType.int64](
        NUM_GPU_THREADS
    )
    ctx.synchronize()

    var scan_kernel = ctx.compile_function[gpu_count_newlines]()
    var temperature_kernel = ctx.compile_function[gpu_parse_temperatures]()

    # Warm both paths before correctness and timing.
    var cpu_expected = run_cpu_scan(
        mapped.ptr,
        size,
        cpu_counts,
        num_cpu_threads,
    )
    ctx.enqueue_function(
        scan_kernel,
        data_buffer,
        counts_buffer,
        size,
        grid_dim=NUM_BLOCKS,
        block_dim=BLOCK_SIZE,
    )
    ctx.enqueue_copy(dst_buf=host_counts, src_buf=counts_buffer)
    ctx.synchronize()

    var gpu_actual = Int64(0)
    for tid in range(NUM_GPU_THREADS):
        gpu_actual += host_counts[tid]

    if gpu_actual != Int64(cpu_expected):
        print(
            "ERROR: newline mismatch; CPU=",
            cpu_expected,
            " GPU=",
            gpu_actual,
        )
        mapped.close()
        external_call["exit", NoneType](Int32(1))

    print("Correctness: PASS (", cpu_expected, " newlines)")
    print(
        "STAGE_MS,",
        Float64(stage_end - stage_start) / 1_000_000.0,
    )

    # A-B-B-A pairs keep the CPU and GPU samples temporally close while the
    # machine remains in normal use. GPU timings include enqueue+synchronize,
    # but not input staging or result readback.
    for pair in range(BENCH_PAIRS):
        var cpu_a_start = perf_counter_ns()
        var cpu_a_count = run_cpu_scan(
            mapped.ptr,
            size,
            cpu_counts,
            num_cpu_threads,
        )
        var cpu_a_end = perf_counter_ns()

        var gpu_b1_start = perf_counter_ns()
        ctx.enqueue_function(
            scan_kernel,
            data_buffer,
            counts_buffer,
            size,
            grid_dim=NUM_BLOCKS,
            block_dim=BLOCK_SIZE,
        )
        ctx.synchronize()
        var gpu_b1_end = perf_counter_ns()

        var gpu_b2_start = perf_counter_ns()
        ctx.enqueue_function(
            scan_kernel,
            data_buffer,
            counts_buffer,
            size,
            grid_dim=NUM_BLOCKS,
            block_dim=BLOCK_SIZE,
        )
        ctx.synchronize()
        var gpu_b2_end = perf_counter_ns()

        var cpu_a2_start = perf_counter_ns()
        var cpu_a2_count = run_cpu_scan(
            mapped.ptr,
            size,
            cpu_counts,
            num_cpu_threads,
        )
        var cpu_a2_end = perf_counter_ns()

        if cpu_a_count != cpu_expected or cpu_a2_count != cpu_expected:
            print("ERROR: CPU benchmark count changed")
            mapped.close()
            external_call["exit", NoneType](Int32(1))

        print(
            "CPU_MS,",
            pair * 2 + 1,
            ",",
            Float64(cpu_a_end - cpu_a_start) / 1_000_000.0,
        )
        print(
            "GPU_MS,",
            pair * 2 + 1,
            ",",
            Float64(gpu_b1_end - gpu_b1_start) / 1_000_000.0,
        )
        print(
            "GPU_MS,",
            pair * 2 + 2,
            ",",
            Float64(gpu_b2_end - gpu_b2_start) / 1_000_000.0,
        )
        print(
            "CPU_MS,",
            pair * 2 + 2,
            ",",
            Float64(cpu_a2_end - cpu_a2_start) / 1_000_000.0,
        )

    # Read the final result once more so timed kernels remain correctness-gated.
    ctx.enqueue_copy(dst_buf=host_counts, src_buf=counts_buffer)
    ctx.synchronize()
    gpu_actual = Int64(0)
    for tid in range(NUM_GPU_THREADS):
        gpu_actual += host_counts[tid]
    if gpu_actual != Int64(cpu_expected):
        print("ERROR: final GPU count changed")
        mapped.close()
        external_call["exit", NoneType](Int32(1))

    print("Final correctness: PASS")

    # Stage two: parse temperatures at newline positions without station
    # hashing or aggregation. Validate both row count and total temperature sum.
    var cpu_temp_expected = run_cpu_temperature_parse(
        mapped.ptr,
        size,
        cpu_counts,
        cpu_sums,
        num_cpu_threads,
    )
    ctx.enqueue_function(
        temperature_kernel,
        data_buffer,
        counts_buffer,
        sums_buffer,
        size,
        grid_dim=NUM_BLOCKS,
        block_dim=BLOCK_SIZE,
    )
    ctx.enqueue_copy(dst_buf=host_counts, src_buf=counts_buffer)
    ctx.enqueue_copy(dst_buf=host_sums, src_buf=sums_buffer)
    ctx.synchronize()

    var gpu_temp_count = Int64(0)
    var gpu_temp_sum = Int64(0)
    for tid in range(NUM_GPU_THREADS):
        gpu_temp_count += host_counts[tid]
        gpu_temp_sum += host_sums[tid]

    if (
        gpu_temp_count != Int64(cpu_temp_expected[0])
        or gpu_temp_sum != cpu_temp_expected[1]
    ):
        print(
            "ERROR: temperature parse mismatch; CPU count/sum=",
            cpu_temp_expected[0],
            "/",
            cpu_temp_expected[1],
            " GPU count/sum=",
            gpu_temp_count,
            "/",
            gpu_temp_sum,
        )
        mapped.close()
        external_call["exit", NoneType](Int32(1))

    print(
        "Temperature correctness: PASS (count=",
        cpu_temp_expected[0],
        " sum=",
        cpu_temp_expected[1],
        ")",
    )

    for pair in range(BENCH_PAIRS):
        var cpu_a_start = perf_counter_ns()
        var cpu_a_result = run_cpu_temperature_parse(
            mapped.ptr,
            size,
            cpu_counts,
            cpu_sums,
            num_cpu_threads,
        )
        var cpu_a_end = perf_counter_ns()

        var gpu_b1_start = perf_counter_ns()
        ctx.enqueue_function(
            temperature_kernel,
            data_buffer,
            counts_buffer,
            sums_buffer,
            size,
            grid_dim=NUM_BLOCKS,
            block_dim=BLOCK_SIZE,
        )
        ctx.synchronize()
        var gpu_b1_end = perf_counter_ns()

        var gpu_b2_start = perf_counter_ns()
        ctx.enqueue_function(
            temperature_kernel,
            data_buffer,
            counts_buffer,
            sums_buffer,
            size,
            grid_dim=NUM_BLOCKS,
            block_dim=BLOCK_SIZE,
        )
        ctx.synchronize()
        var gpu_b2_end = perf_counter_ns()

        var cpu_a2_start = perf_counter_ns()
        var cpu_a2_result = run_cpu_temperature_parse(
            mapped.ptr,
            size,
            cpu_counts,
            cpu_sums,
            num_cpu_threads,
        )
        var cpu_a2_end = perf_counter_ns()

        if (
            cpu_a_result != cpu_temp_expected
            or cpu_a2_result != cpu_temp_expected
        ):
            print("ERROR: CPU temperature benchmark result changed")
            mapped.close()
            external_call["exit", NoneType](Int32(1))

        print(
            "CPU_TEMP_MS,",
            pair * 2 + 1,
            ",",
            Float64(cpu_a_end - cpu_a_start) / 1_000_000.0,
        )
        print(
            "GPU_TEMP_MS,",
            pair * 2 + 1,
            ",",
            Float64(gpu_b1_end - gpu_b1_start) / 1_000_000.0,
        )
        print(
            "GPU_TEMP_MS,",
            pair * 2 + 2,
            ",",
            Float64(gpu_b2_end - gpu_b2_start) / 1_000_000.0,
        )
        print(
            "CPU_TEMP_MS,",
            pair * 2 + 2,
            ",",
            Float64(cpu_a2_end - cpu_a2_start) / 1_000_000.0,
        )

    ctx.enqueue_copy(dst_buf=host_counts, src_buf=counts_buffer)
    ctx.enqueue_copy(dst_buf=host_sums, src_buf=sums_buffer)
    ctx.synchronize()
    gpu_temp_count = Int64(0)
    gpu_temp_sum = Int64(0)
    for tid in range(NUM_GPU_THREADS):
        gpu_temp_count += host_counts[tid]
        gpu_temp_sum += host_sums[tid]
    if (
        gpu_temp_count != Int64(cpu_temp_expected[0])
        or gpu_temp_sum != cpu_temp_expected[1]
    ):
        print("ERROR: final GPU temperature result changed")
        mapped.close()
        external_call["exit", NoneType](Int32(1))

    print("Final temperature correctness: PASS")
    cpu_counts.free()
    cpu_sums.free()
    mapped.close()
