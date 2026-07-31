"""Staged GPU investigation: scanning, parsing, and station indexing.

This executable measures three gates before station aggregation: occupied
newline scanning, fixed-point temperature parsing, and dense station indexing.
Each gate has an exact parallel CPU reference.

The GPU kernel uses 256-thread blocks. Adjacent lanes read adjacent bytes, and
each lane advances by the total grid width. The station kernel identifies the
fixed 413-name universe by normalized eight-byte suffix, then maps perfect-hash
slots to dense IDs with a compact occupancy bitset and rank prefix.

Input preparation, CPU time, GPU kernel time, and result readback are reported
separately. The GPU input is staged through a DeviceBuffer; zero-copy
mmap/Metal interop is intentionally a separate experiment.
"""

from std.bit import count_leading_zeros, count_trailing_zeros, pop_count
from std.ffi import external_call
from std.gpu import global_idx
from std.gpu.host import DeviceContext
from std.memory import UnsafePointer, alloc, bitcast
from std.sys import argv, has_accelerator
from std.sys.info import num_logical_cores
from std.time import perf_counter_ns

from IO.mmap import MappedFile
from engine.stations_data import (
    PERFECT_CAPACITY,
    PERFECT_MULTIPLIER,
    PERFECT_SHIFT,
    STATION_HASHES,
    STATION_NAMES,
)


comptime MAX_FILE_BYTES = 4_200_000_000
comptime BLOCK_SIZE = 256
comptime NUM_BLOCKS = 256
comptime NUM_GPU_THREADS = BLOCK_SIZE * NUM_BLOCKS
comptime BENCH_PAIRS = 5
comptime SUFFIX_CAPACITY = 8192
comptime SUFFIX_MULTIPLIER = UInt64(3202095764612966159)
comptime SUFFIX_SHIFT = 51
comptime SUFFIX_WORDS = SUFFIX_CAPACITY // 64
comptime SPRINGS_SUFFIX = UInt64(0x73676E6972705320)
comptime ALICE_SPRINGS_ID = 83
comptime PALM_SPRINGS_ID = 147
comptime LAST_DENSE_ID = len(STATION_HASHES) - 1

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


def gpu_index_stations(
    data: UnsafePointer[UInt8, MutAnyOrigin],
    suffix_occupancy: UnsafePointer[UInt64, MutAnyOrigin],
    suffix_prefix: UnsafePointer[Int16, MutAnyOrigin],
    counts: UnsafePointer[Int64, MutAnyOrigin],
    temp_sums: UnsafePointer[Int64, MutAnyOrigin],
    dense_sums: UnsafePointer[Int64, MutAnyOrigin],
    dense_sq_sums: UnsafePointer[Int64, MutAnyOrigin],
    invalid_counts: UnsafePointer[Int64, MutAnyOrigin],
    size: Int,
):
    """Map stations by their unique normalized eight-byte suffix."""
    var tid = Int(global_idx.x)
    var count = Int64(0)
    var temp_total = Int64(0)
    var dense_total = Int64(0)
    var dense_sq_total = Int64(0)
    var invalid = Int64(0)
    var i = tid

    while i < size:
        if data[i] == UInt8(10):
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

            # Temperature text is always one of x.x, xx.x, -x.x, -xx.x.
            # This gives the semicolon without another forward search.
            var temp_width = 6 - Int(c5 == 59) - 2 * Int(c4 == 59)
            var semicolon = i - temp_width

            # Normalize the full name for short stations and the last eight
            # bytes for longer stations. The only suffix collision in the
            # generated universe is resolved with the ninth byte below.
            var suffix_key = UInt64(0)
            if semicolon >= 8:
                suffix_key = (data + semicolon - 8).bitcast[
                    UInt64
                ]().load[alignment=1]()
                var newline_xor = (
                    suffix_key ^ UInt64(0x0A0A0A0A0A0A0A0A)
                )
                var newline_bits = (
                    (newline_xor - UInt64(0x0101010101010101))
                    & ~newline_xor
                    & UInt64(0x8080808080808080)
                )
                if newline_bits != 0:
                    var newline_byte = (
                        63 - Int(count_leading_zeros(newline_bits))
                    ) // 8
                    suffix_key >>= UInt64((newline_byte + 1) * 8)
            else:
                var byte_index = 0
                while byte_index < semicolon:
                    suffix_key |= (
                        UInt64(data[byte_index])
                        << UInt64(byte_index * 8)
                    )
                    byte_index += 1

            var dense = -1
            var slot = Int(
                (suffix_key * SUFFIX_MULTIPLIER)
                >> UInt64(SUFFIX_SHIFT)
            )
            var word_index = slot >> 6
            var bit_index = slot & 63
            var slot_bit = UInt64(1) << UInt64(bit_index)
            if suffix_occupancy[word_index] & slot_bit != 0:
                var lower_bits = suffix_occupancy[word_index] & (
                    slot_bit - UInt64(1)
                )
                dense = (
                    Int(suffix_prefix[word_index])
                    + Int(pop_count(lower_bits))
                )
            if (
                suffix_key == SPRINGS_SUFFIX
                and data[semicolon - 9] == UInt8(109)
            ):
                dense = LAST_DENSE_ID

            temp_total += Int64(temp)
            count += 1
            if dense < 0:
                invalid += 1
            else:
                dense_total += Int64(dense)
                dense_sq_total += Int64(dense * dense)

        i += NUM_GPU_THREADS

    counts[tid] = count
    temp_sums[tid] = temp_total
    dense_sums[tid] = dense_total
    dense_sq_sums[tid] = dense_sq_total
    invalid_counts[tid] = invalid


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


@always_inline
def index_stations_simd(
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    slot_to_dense: UnsafePointer[Int16, MutUntrackedOrigin],
    start: Int,
    end: Int,
) -> Tuple[Int64, Int64, Int64, Int64, Int64]:
    """Index stations for newlines in one byte range with SIMD discovery."""
    comptime width = 16
    comptime nl_vec = SIMD[DType.uint8, width](10)
    var count = Int64(0)
    var temp_total = Int64(0)
    var dense_total = Int64(0)
    var dense_sq_total = Int64(0)
    var invalid = Int64(0)
    var row_start = start
    while row_start > 0 and ptr[row_start - 1] != UInt8(10):
        row_start -= 1
    var i = start

    while i + width <= end:
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

                var temp_width = 6 - Int(c5 == 59) - 2 * Int(c4 == 59)
                var semicolon = nl - temp_width
                var name_length = semicolon - row_start
                var head = UInt64(ptr[row_start])
                head |= UInt64(ptr[row_start + 1]) << 8
                head |= UInt64(ptr[row_start + 2]) << 16
                var hash_value = UInt64(name_length)
                hash_value |= (head & 0xFFFFFF) << 8
                hash_value |= UInt64(ptr[semicolon - 3]) << 32
                var slot = Int(
                    (hash_value * PERFECT_MULTIPLIER)
                    >> UInt64(PERFECT_SHIFT)
                )
                var dense = Int(slot_to_dense[slot])

                temp_total += Int64(temp)
                count += 1
                if dense < 0:
                    invalid += 1
                else:
                    dense_total += Int64(dense)
                    dense_sq_total += Int64(dense * dense)
                row_start = nl + 1
                final_mask &= final_mask - 1
        i += width

    while i < end:
        if ptr[i] == UInt8(10):
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

            var temp_width = 6 - Int(c5 == 59) - 2 * Int(c4 == 59)
            var semicolon = i - temp_width
            var name_length = semicolon - row_start
            var head = UInt64(ptr[row_start])
            head |= UInt64(ptr[row_start + 1]) << 8
            head |= UInt64(ptr[row_start + 2]) << 16
            var hash_value = UInt64(name_length)
            hash_value |= (head & 0xFFFFFF) << 8
            hash_value |= UInt64(ptr[semicolon - 3]) << 32
            var slot = Int(
                (hash_value * PERFECT_MULTIPLIER)
                >> UInt64(PERFECT_SHIFT)
            )
            var dense = Int(slot_to_dense[slot])

            temp_total += Int64(temp)
            count += 1
            if dense < 0:
                invalid += 1
            else:
                dense_total += Int64(dense)
                dense_sq_total += Int64(dense * dense)
            row_start = i + 1
        i += 1

    return count, temp_total, dense_total, dense_sq_total, invalid


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


def run_cpu_station_index(
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    slot_to_dense: UnsafePointer[Int16, MutUntrackedOrigin],
    size: Int,
    counts_ptr: UnsafePointer[Int64, MutUntrackedOrigin],
    temp_sums_ptr: UnsafePointer[Int64, MutUntrackedOrigin],
    dense_sums_ptr: UnsafePointer[Int64, MutUntrackedOrigin],
    dense_sq_sums_ptr: UnsafePointer[Int64, MutUntrackedOrigin],
    invalid_counts_ptr: UnsafePointer[Int64, MutUntrackedOrigin],
    num_threads: Int,
) raises -> Tuple[Int64, Int64, Int64, Int64, Int64]:
    """Index stations over equal byte ranges on the CPU."""
    @parameter
    def process_chunk(tid: Int):
        var start = (size * tid) // num_threads
        var end = (size * (tid + 1)) // num_threads
        var result = index_stations_simd(
            ptr, slot_to_dense, start, end
        )
        counts_ptr[tid] = result[0]
        temp_sums_ptr[tid] = result[1]
        dense_sums_ptr[tid] = result[2]
        dense_sq_sums_ptr[tid] = result[3]
        invalid_counts_ptr[tid] = result[4]

    def process_chunk_unified(tid: Int):
        process_chunk(tid)

    var cpu_ctx = DeviceContext(api="cpu")
    cpu_ctx.enqueue_cpu_range(process_chunk_unified, count=num_threads)
    cpu_ctx.synchronize()

    var total_count = Int64(0)
    var total_temp_sum = Int64(0)
    var total_dense_sum = Int64(0)
    var total_dense_sq_sum = Int64(0)
    var total_invalid = Int64(0)
    for tid in range(num_threads):
        total_count += counts_ptr[tid]
        total_temp_sum += temp_sums_ptr[tid]
        total_dense_sum += dense_sums_ptr[tid]
        total_dense_sq_sum += dense_sq_sums_ptr[tid]
        total_invalid += invalid_counts_ptr[tid]
    return (
        total_count,
        total_temp_sum,
        total_dense_sum,
        total_dense_sq_sum,
        total_invalid,
    )


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
    var cpu_index_counts = alloc[Int64](num_cpu_threads)
    var cpu_index_temp_sums = alloc[Int64](num_cpu_threads)
    var cpu_dense_sums = alloc[Int64](num_cpu_threads)
    var cpu_dense_sq_sums = alloc[Int64](num_cpu_threads)
    var cpu_invalid_counts = alloc[Int64](num_cpu_threads)
    var slot_to_dense = alloc[Int16](PERFECT_CAPACITY)
    var station_suffix_slots = alloc[Int](len(STATION_HASHES))
    var suffix_occupancy = alloc[UInt64](SUFFIX_WORDS)
    var suffix_prefix = alloc[Int16](SUFFIX_WORDS)
    for slot in range(PERFECT_CAPACITY):
        slot_to_dense[slot] = -1
    for word_index in range(SUFFIX_WORDS):
        suffix_occupancy[word_index] = 0

    comptime for station_id in range(len(STATION_HASHES)):
        var station_name = String(STATION_NAMES[station_id])
        var station_bytes = station_name.as_bytes()
        var station_length = len(station_bytes)
        var suffix_length = min(station_length, 8)
        var suffix_key = UInt64(0)
        for suffix_index in range(suffix_length):
            suffix_key |= (
                UInt64(
                    station_bytes[
                        station_length - suffix_length + suffix_index
                    ]
                )
                << UInt64(suffix_index * 8)
            )
        var suffix_slot = Int(
            (suffix_key * SUFFIX_MULTIPLIER) >> UInt64(SUFFIX_SHIFT)
        )
        station_suffix_slots[station_id] = suffix_slot
        suffix_occupancy[suffix_slot >> 6] |= (
            UInt64(1) << UInt64(suffix_slot & 63)
        )

    var occupied_before = 0
    for word_index in range(SUFFIX_WORDS):
        suffix_prefix[word_index] = Int16(occupied_before)
        occupied_before += Int(pop_count(suffix_occupancy[word_index]))
    if (
        occupied_before != len(STATION_HASHES) - 1
        or station_suffix_slots[ALICE_SPRINGS_ID]
        != station_suffix_slots[PALM_SPRINGS_ID]
    ):
        print(
            "ERROR: expected exactly one generated suffix collision; got ",
            len(STATION_HASHES) - occupied_before,
        )
        mapped.close()
        external_call["exit", NoneType](Int32(1))

    comptime for station_id in range(len(STATION_HASHES)):
        comptime station_hash = UInt64(STATION_HASHES[station_id])
        comptime station_slot = Int(
            (station_hash * PERFECT_MULTIPLIER) >> UInt64(PERFECT_SHIFT)
        )
        var suffix_slot = station_suffix_slots[station_id]
        var word_index = suffix_slot >> 6
        var bit_index = suffix_slot & 63
        var lower_bits = suffix_occupancy[word_index] & (
            (UInt64(1) << UInt64(bit_index)) - UInt64(1)
        )
        var dense = (
            Int(suffix_prefix[word_index]) + Int(pop_count(lower_bits))
        )
        if station_id == PALM_SPRINGS_ID:
            dense = LAST_DENSE_ID
        slot_to_dense[station_slot] = Int16(dense)

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
    var dense_sums_buffer = ctx.enqueue_create_buffer[DType.int64](
        NUM_GPU_THREADS
    )
    var dense_sq_sums_buffer = ctx.enqueue_create_buffer[DType.int64](
        NUM_GPU_THREADS
    )
    var invalid_counts_buffer = ctx.enqueue_create_buffer[DType.int64](
        NUM_GPU_THREADS
    )
    var suffix_occupancy_buffer = ctx.enqueue_create_buffer[DType.uint64](
        SUFFIX_WORDS
    )
    var suffix_prefix_buffer = ctx.enqueue_create_buffer[DType.int16](
        SUFFIX_WORDS
    )
    ctx.enqueue_copy(suffix_occupancy_buffer, suffix_occupancy)
    ctx.enqueue_copy(suffix_prefix_buffer, suffix_prefix)
    var host_counts = ctx.enqueue_create_host_buffer[DType.int64](
        NUM_GPU_THREADS
    )
    var host_sums = ctx.enqueue_create_host_buffer[DType.int64](
        NUM_GPU_THREADS
    )
    var host_dense_sums = ctx.enqueue_create_host_buffer[DType.int64](
        NUM_GPU_THREADS
    )
    var host_dense_sq_sums = ctx.enqueue_create_host_buffer[DType.int64](
        NUM_GPU_THREADS
    )
    var host_invalid_counts = ctx.enqueue_create_host_buffer[DType.int64](
        NUM_GPU_THREADS
    )
    ctx.synchronize()

    var scan_kernel = ctx.compile_function[gpu_count_newlines]()
    var temperature_kernel = ctx.compile_function[gpu_parse_temperatures]()
    var station_index_kernel = ctx.compile_function[gpu_index_stations]()

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

    # Stage three: recover each row's station-name boundary with backward SIMD
    # masks and map the name to a dense 0..412 ID.
    var cpu_index_expected = run_cpu_station_index(
        mapped.ptr,
        slot_to_dense,
        size,
        cpu_index_counts,
        cpu_index_temp_sums,
        cpu_dense_sums,
        cpu_dense_sq_sums,
        cpu_invalid_counts,
        num_cpu_threads,
    )
    ctx.enqueue_function(
        station_index_kernel,
        data_buffer,
        suffix_occupancy_buffer,
        suffix_prefix_buffer,
        counts_buffer,
        sums_buffer,
        dense_sums_buffer,
        dense_sq_sums_buffer,
        invalid_counts_buffer,
        size,
        grid_dim=NUM_BLOCKS,
        block_dim=BLOCK_SIZE,
    )
    ctx.enqueue_copy(dst_buf=host_counts, src_buf=counts_buffer)
    ctx.enqueue_copy(dst_buf=host_sums, src_buf=sums_buffer)
    ctx.enqueue_copy(dst_buf=host_dense_sums, src_buf=dense_sums_buffer)
    ctx.enqueue_copy(
        dst_buf=host_dense_sq_sums, src_buf=dense_sq_sums_buffer
    )
    ctx.enqueue_copy(
        dst_buf=host_invalid_counts, src_buf=invalid_counts_buffer
    )
    ctx.synchronize()

    var gpu_index_count = Int64(0)
    var gpu_index_temp_sum = Int64(0)
    var gpu_dense_sum = Int64(0)
    var gpu_dense_sq_sum = Int64(0)
    var gpu_invalid_count = Int64(0)
    for tid in range(NUM_GPU_THREADS):
        gpu_index_count += host_counts[tid]
        gpu_index_temp_sum += host_sums[tid]
        gpu_dense_sum += host_dense_sums[tid]
        gpu_dense_sq_sum += host_dense_sq_sums[tid]
        gpu_invalid_count += host_invalid_counts[tid]
    var gpu_index_actual = (
        gpu_index_count,
        gpu_index_temp_sum,
        gpu_dense_sum,
        gpu_dense_sq_sum,
        gpu_invalid_count,
    )

    if gpu_index_actual != cpu_index_expected:
        print(
            "ERROR: station index mismatch; CPU=",
            cpu_index_expected,
            " GPU=",
            gpu_index_actual,
        )
        mapped.close()
        external_call["exit", NoneType](Int32(1))
    if cpu_index_expected[4] != 0:
        print(
            "ERROR: generated perfect hash rejected ",
            cpu_index_expected[4],
            " rows",
        )
        mapped.close()
        external_call["exit", NoneType](Int32(1))

    print(
        "Station index correctness: PASS (count/temp/dense/dense_sq=",
        cpu_index_expected[0],
        "/",
        cpu_index_expected[1],
        "/",
        cpu_index_expected[2],
        "/",
        cpu_index_expected[3],
        ")",
    )

    for pair in range(BENCH_PAIRS):
        var cpu_a_start = perf_counter_ns()
        var cpu_a_result = run_cpu_station_index(
            mapped.ptr,
            slot_to_dense,
            size,
            cpu_index_counts,
            cpu_index_temp_sums,
            cpu_dense_sums,
            cpu_dense_sq_sums,
            cpu_invalid_counts,
            num_cpu_threads,
        )
        var cpu_a_end = perf_counter_ns()

        var gpu_b1_start = perf_counter_ns()
        ctx.enqueue_function(
            station_index_kernel,
            data_buffer,
            suffix_occupancy_buffer,
            suffix_prefix_buffer,
            counts_buffer,
            sums_buffer,
            dense_sums_buffer,
            dense_sq_sums_buffer,
            invalid_counts_buffer,
            size,
            grid_dim=NUM_BLOCKS,
            block_dim=BLOCK_SIZE,
        )
        ctx.synchronize()
        var gpu_b1_end = perf_counter_ns()

        var gpu_b2_start = perf_counter_ns()
        ctx.enqueue_function(
            station_index_kernel,
            data_buffer,
            suffix_occupancy_buffer,
            suffix_prefix_buffer,
            counts_buffer,
            sums_buffer,
            dense_sums_buffer,
            dense_sq_sums_buffer,
            invalid_counts_buffer,
            size,
            grid_dim=NUM_BLOCKS,
            block_dim=BLOCK_SIZE,
        )
        ctx.synchronize()
        var gpu_b2_end = perf_counter_ns()

        var cpu_a2_start = perf_counter_ns()
        var cpu_a2_result = run_cpu_station_index(
            mapped.ptr,
            slot_to_dense,
            size,
            cpu_index_counts,
            cpu_index_temp_sums,
            cpu_dense_sums,
            cpu_dense_sq_sums,
            cpu_invalid_counts,
            num_cpu_threads,
        )
        var cpu_a2_end = perf_counter_ns()

        if (
            cpu_a_result != cpu_index_expected
            or cpu_a2_result != cpu_index_expected
        ):
            print("ERROR: CPU station benchmark result changed")
            mapped.close()
            external_call["exit", NoneType](Int32(1))

        print(
            "CPU_INDEX_MS,",
            pair * 2 + 1,
            ",",
            Float64(cpu_a_end - cpu_a_start) / 1_000_000.0,
        )
        print(
            "GPU_INDEX_MS,",
            pair * 2 + 1,
            ",",
            Float64(gpu_b1_end - gpu_b1_start) / 1_000_000.0,
        )
        print(
            "GPU_INDEX_MS,",
            pair * 2 + 2,
            ",",
            Float64(gpu_b2_end - gpu_b2_start) / 1_000_000.0,
        )
        print(
            "CPU_INDEX_MS,",
            pair * 2 + 2,
            ",",
            Float64(cpu_a2_end - cpu_a2_start) / 1_000_000.0,
        )

    ctx.enqueue_copy(dst_buf=host_counts, src_buf=counts_buffer)
    ctx.enqueue_copy(dst_buf=host_sums, src_buf=sums_buffer)
    ctx.enqueue_copy(dst_buf=host_dense_sums, src_buf=dense_sums_buffer)
    ctx.enqueue_copy(
        dst_buf=host_dense_sq_sums, src_buf=dense_sq_sums_buffer
    )
    ctx.enqueue_copy(
        dst_buf=host_invalid_counts, src_buf=invalid_counts_buffer
    )
    ctx.synchronize()
    gpu_index_count = 0
    gpu_index_temp_sum = 0
    gpu_dense_sum = 0
    gpu_dense_sq_sum = 0
    gpu_invalid_count = 0
    for tid in range(NUM_GPU_THREADS):
        gpu_index_count += host_counts[tid]
        gpu_index_temp_sum += host_sums[tid]
        gpu_dense_sum += host_dense_sums[tid]
        gpu_dense_sq_sum += host_dense_sq_sums[tid]
        gpu_invalid_count += host_invalid_counts[tid]
    gpu_index_actual = (
        gpu_index_count,
        gpu_index_temp_sum,
        gpu_dense_sum,
        gpu_dense_sq_sum,
        gpu_invalid_count,
    )
    if gpu_index_actual != cpu_index_expected:
        print("ERROR: final GPU station index result changed")
        mapped.close()
        external_call["exit", NoneType](Int32(1))

    print("Final station index correctness: PASS")
    cpu_counts.free()
    cpu_sums.free()
    cpu_index_counts.free()
    cpu_index_temp_sums.free()
    cpu_dense_sums.free()
    cpu_dense_sq_sums.free()
    cpu_invalid_counts.free()
    slot_to_dense.free()
    station_suffix_slots.free()
    suffix_occupancy.free()
    suffix_prefix.free()
    mapped.close()
