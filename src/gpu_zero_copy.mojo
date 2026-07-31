"""Metal scan, temperature, and station gates over a no-copy Mojo mmap."""

from std.bit import count_trailing_zeros, pop_count
from std.ffi import OwnedDLHandle, external_call
from std.memory import UnsafePointer, alloc, bitcast
from std.sys import argv
from std.time import perf_counter_ns

from IO.mmap import MappedFile
from engine.stations_data import (
    PERFECT_CAPACITY,
    PERFECT_MULTIPLIER,
    PERFECT_SHIFT,
    STATION_HASHES,
    STATION_NAMES,
)


comptime WARM_RUNS = 5
comptime FAILURE_COUNT = UInt64(0xFFFFFFFFFFFFFFFF)
comptime MAX_STATION_BYTES = 4_200_000_000
comptime SUFFIX_CAPACITY = 8192
comptime SUFFIX_MULTIPLIER = UInt64(3202095764612966159)
comptime SUFFIX_SHIFT = 51
comptime SUFFIX_WORDS = SUFFIX_CAPACITY // 64
comptime ALICE_SPRINGS_ID = 83
comptime PALM_SPRINGS_ID = 147
comptime LAST_DENSE_ID = len(STATION_HASHES) - 1

comptime OpaquePtr = UnsafePointer[NoneType, MutUntrackedOrigin]


@always_inline
def count_newlines_simd(
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin], size: Int
) -> Int64:
    comptime width = 16
    comptime newline = SIMD[DType.uint8, width](10)
    var count = Int64(0)
    var offset = 0

    while offset + width <= size:
        var chunk = ptr.load[width=width](offset)
        var matches = chunk.eq(newline)
        if matches.reduce_or():
            var bytes = matches.cast[DType.uint8]() & 1
            var words = bitcast[DType.uint64, 2](bytes)
            var low = (words[0] * 0x0102040810204080) >> 56
            var high = (words[1] * 0x0102040810204080) >> 56
            var mask = Int(low) | (Int(high) << 8)
            while mask != 0:
                count += 1
                mask &= mask - 1
        offset += width

    while offset < size:
        count += Int64(ptr[offset] == 10)
        offset += 1
    return count


@always_inline
def parse_temperatures_simd(
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin], size: Int
) -> Tuple[Int, Int64]:
    """Return exact row count and fixed-point temperature sum."""
    comptime width = 16
    comptime newline = SIMD[DType.uint8, width](10)
    var count = 0
    var total = Int64(0)
    var offset = 0

    while offset + width <= size:
        var chunk = ptr.load[width=width](offset)
        var matches = chunk.eq(newline)
        if matches.reduce_or():
            var bytes = matches.cast[DType.uint8]() & 1
            var words = bitcast[DType.uint64, 2](bytes)
            var low = (words[0] * 0x0102040810204080) >> 56
            var high = (words[1] * 0x0102040810204080) >> 56
            var mask = Int(low) | (Int(high) << 8)
            while mask != 0:
                var nl = offset + Int(count_trailing_zeros(mask))
                var c_frac = Int(ptr[nl - 1] & 0x0F)
                var c_units = Int(ptr[nl - 3] & 0x0F)
                var c4 = Int(ptr[nl - 4])
                var c5 = Int(ptr[nl - 5])
                var c4_value = c4 & 0x0F
                var has_tens = Int(c4_value <= 9)
                var is_negative = Int(c4 == 45) | Int(c5 == 45)
                var temperature = (
                    c4_value * has_tens * 100
                    + c_units * 10
                    + c_frac
                )
                temperature *= 1 - is_negative * 2
                total += Int64(temperature)
                count += 1
                mask &= mask - 1
        offset += width

    while offset < size:
        if ptr[offset] == 10:
            var c_frac = Int(ptr[offset - 1] & 0x0F)
            var c_units = Int(ptr[offset - 3] & 0x0F)
            var c4 = Int(ptr[offset - 4])
            var c5 = Int(ptr[offset - 5])
            var c4_value = c4 & 0x0F
            var has_tens = Int(c4_value <= 9)
            var is_negative = Int(c4 == 45) | Int(c5 == 45)
            var temperature = (
                c4_value * has_tens * 100 + c_units * 10 + c_frac
            )
            temperature *= 1 - is_negative * 2
            total += Int64(temperature)
            count += 1
        offset += 1
    return count, total


@always_inline
def index_stations_simd(
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    slot_to_dense: UnsafePointer[Int16, MutUntrackedOrigin],
    size: Int,
) -> Tuple[Int64, Int64, Int64, Int64, Int64]:
    """Independent perfect-hash oracle for the full mapped file."""
    comptime width = 16
    comptime newline = SIMD[DType.uint8, width](10)
    var count = Int64(0)
    var temperature_total = Int64(0)
    var dense_total = Int64(0)
    var dense_sq_total = Int64(0)
    var invalid = Int64(0)
    var row_start = 0
    var offset = 0

    while offset + width <= size:
        var chunk = ptr.load[width=width](offset)
        var matches = chunk.eq(newline)
        if matches.reduce_or():
            var bytes = matches.cast[DType.uint8]() & 1
            var words = bitcast[DType.uint64, 2](bytes)
            var low = (words[0] * 0x0102040810204080) >> 56
            var high = (words[1] * 0x0102040810204080) >> 56
            var mask = Int(low) | (Int(high) << 8)
            while mask != 0:
                var nl = offset + Int(count_trailing_zeros(mask))
                var c_frac = Int(ptr[nl - 1] & 0x0F)
                var c_units = Int(ptr[nl - 3] & 0x0F)
                var c4 = Int(ptr[nl - 4])
                var c5 = Int(ptr[nl - 5])
                var c4_value = c4 & 0x0F
                var has_tens = Int(c4_value <= 9)
                var is_negative = Int(c4 == 45) | Int(c5 == 45)
                var temperature = (
                    c4_value * has_tens * 100
                    + c_units * 10
                    + c_frac
                )
                temperature *= 1 - is_negative * 2

                var temperature_width = (
                    6 - Int(c5 == 59) - 2 * Int(c4 == 59)
                )
                var semicolon = nl - temperature_width
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

                temperature_total += Int64(temperature)
                count += 1
                if dense < 0:
                    invalid += 1
                else:
                    dense_total += Int64(dense)
                    dense_sq_total += Int64(dense * dense)
                row_start = nl + 1
                mask &= mask - 1
        offset += width

    while offset < size:
        if ptr[offset] == UInt8(10):
            var c_frac = Int(ptr[offset - 1] & 0x0F)
            var c_units = Int(ptr[offset - 3] & 0x0F)
            var c4 = Int(ptr[offset - 4])
            var c5 = Int(ptr[offset - 5])
            var c4_value = c4 & 0x0F
            var has_tens = Int(c4_value <= 9)
            var is_negative = Int(c4 == 45) | Int(c5 == 45)
            var temperature = (
                c4_value * has_tens * 100 + c_units * 10 + c_frac
            )
            temperature *= 1 - is_negative * 2

            var temperature_width = (
                6 - Int(c5 == 59) - 2 * Int(c4 == 59)
            )
            var semicolon = offset - temperature_width
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

            temperature_total += Int64(temperature)
            count += 1
            if dense < 0:
                invalid += 1
            else:
                dense_total += Int64(dense)
                dense_sq_total += Int64(dense * dense)
            row_start = offset + 1
        offset += 1

    return (
        count,
        temperature_total,
        dense_total,
        dense_sq_total,
        invalid,
    )


def main() raises:
    if len(argv()) < 3:
        print(
            "Usage: gpu_zero_copy <measurements.txt> <bridge.dylib>",
            "[--temperature|--station] [--cpu-first]",
        )
        external_call["exit", NoneType](Int32(2))

    var input_path = argv()[1]
    var library_path = argv()[2]
    var cpu_first = False
    var temperature_mode = False
    var station_mode = False
    for arg_index in range(3, len(argv())):
        if argv()[arg_index] == "--cpu-first":
            cpu_first = True
        elif argv()[arg_index] == "--temperature":
            temperature_mode = True
        elif argv()[arg_index] == "--station":
            station_mode = True
        else:
            print("ERROR: unknown option:", argv()[arg_index])
            external_call["exit", NoneType](Int32(2))
    if temperature_mode and station_mode:
        print("ERROR: choose either --temperature or --station")
        external_call["exit", NoneType](Int32(2))
    var mapped = MappedFile(input_path)
    if station_mode and mapped.size > MAX_STATION_BYTES:
        print(
            "ERROR: station mode supports at most",
            MAX_STATION_BYTES,
            "bytes; got",
            mapped.size,
        )
        mapped.close()
        external_call["exit", NoneType](Int32(2))
    var page_size = Int(external_call["getpagesize", Int32]())
    var mapped_length = (
        (mapped.size + page_size - 1) // page_size
    ) * page_size

    var library = OwnedDLHandle(library_path)
    var create = library.get_function[OpaquePtr]("metal_scan_create")
    var wrap = library.get_function[Int32]("metal_scan_wrap")
    var run = library.get_function[UInt64]("metal_scan_count_newlines")
    var run_temperature = library.get_function[UInt64](
        "metal_scan_parse_temperatures"
    )
    var temperature_sum = library.get_function[Int64](
        "metal_scan_temperature_sum"
    )
    var set_station_tables = library.get_function[Int32](
        "metal_scan_set_station_tables"
    )
    var run_station = library.get_function[UInt64](
        "metal_scan_index_stations"
    )
    var station_setup_ns = library.get_function[UInt64](
        "metal_scan_station_setup_ns"
    )
    var dense_sum = library.get_function[Int64]("metal_scan_dense_sum")
    var dense_sq_sum = library.get_function[Int64](
        "metal_scan_dense_sq_sum"
    )
    var invalid_count = library.get_function[Int64](
        "metal_scan_invalid_count"
    )
    var context_ns = library.get_function[UInt64]("metal_scan_context_ns")
    var wrap_ns = library.get_function[UInt64]("metal_scan_wrap_ns")
    var run_wall_ns = library.get_function[UInt64](
        "metal_scan_run_wall_ns"
    )
    var gpu_ns = library.get_function[UInt64]("metal_scan_gpu_ns")
    var report_error = library.get_function[NoneType](
        "metal_scan_report_error"
    )
    var destroy = library.get_function[NoneType]("metal_scan_destroy")

    var ctx = create()
    if Int(ctx) == 0:
        print("ERROR: Metal context allocation returned null")
        mapped.close()
        external_call["exit", NoneType](Int32(1))

    if wrap(
        ctx,
        mapped.ptr.bitcast[NoneType](),
        UInt(mapped.size),
        UInt(mapped_length),
    ) != 0:
        report_error(ctx)
        destroy(ctx)
        mapped.close()
        external_call["exit", NoneType](Int32(1))

    print("Input bytes:", mapped.size)
    print("VM page bytes:", page_size)
    print("Metal buffer bytes:", mapped_length)
    if cpu_first:
        print("FIRST_TOUCH_ORDER,CPU_FIRST")
    else:
        print("FIRST_TOUCH_ORDER,GPU_FIRST")
    print("CONTEXT_MS,", Float64(context_ns(ctx)) / 1_000_000.0)
    print("WRAP_MS,", Float64(wrap_ns(ctx)) / 1_000_000.0)

    if station_mode:
        var table_started = perf_counter_ns()
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
                            station_length
                            - suffix_length
                            + suffix_index
                        ]
                    )
                    << UInt64(suffix_index * 8)
                )
            var suffix_slot = Int(
                (suffix_key * SUFFIX_MULTIPLIER)
                >> UInt64(SUFFIX_SHIFT)
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
            print("ERROR: station suffix table invariant failed")
            slot_to_dense.free()
            station_suffix_slots.free()
            suffix_occupancy.free()
            suffix_prefix.free()
            destroy(ctx)
            mapped.close()
            external_call["exit", NoneType](Int32(1))

        comptime for station_id in range(len(STATION_HASHES)):
            comptime station_hash = UInt64(STATION_HASHES[station_id])
            comptime station_slot = Int(
                (station_hash * PERFECT_MULTIPLIER)
                >> UInt64(PERFECT_SHIFT)
            )
            var suffix_slot = station_suffix_slots[station_id]
            var word_index = suffix_slot >> 6
            var bit_index = suffix_slot & 63
            var lower_bits = suffix_occupancy[word_index] & (
                (UInt64(1) << UInt64(bit_index)) - UInt64(1)
            )
            var dense = (
                Int(suffix_prefix[word_index])
                + Int(pop_count(lower_bits))
            )
            if station_id == PALM_SPRINGS_ID:
                dense = LAST_DENSE_ID
            slot_to_dense[station_slot] = Int16(dense)

        if set_station_tables(
            ctx,
            suffix_occupancy.bitcast[NoneType](),
            UInt(SUFFIX_WORDS * 8),
            suffix_prefix.bitcast[NoneType](),
            UInt(SUFFIX_WORDS * 2),
        ) != 0:
            report_error(ctx)
            slot_to_dense.free()
            station_suffix_slots.free()
            suffix_occupancy.free()
            suffix_prefix.free()
            destroy(ctx)
            mapped.close()
            external_call["exit", NoneType](Int32(1))
        var table_finished = perf_counter_ns()
        station_suffix_slots.free()
        suffix_occupancy.free()
        suffix_prefix.free()

        print(
            "HOST_STATION_TABLE_MS,",
            Float64(table_finished - table_started) / 1_000_000.0,
        )
        print(
            "METAL_STATION_TABLE_MS,",
            Float64(station_setup_ns(ctx)) / 1_000_000.0,
        )

        var cpu_started = 0
        var cpu_finished = 0
        var expected_count = Int64(0)
        var expected_temperature_sum = Int64(0)
        var expected_dense_sum = Int64(0)
        var expected_dense_sq_sum = Int64(0)
        var expected_invalid = Int64(0)
        if cpu_first:
            cpu_started = perf_counter_ns()
            var expected = index_stations_simd(
                mapped.ptr, slot_to_dense, mapped.size
            )
            cpu_finished = perf_counter_ns()
            expected_count = expected[0]
            expected_temperature_sum = expected[1]
            expected_dense_sum = expected[2]
            expected_dense_sq_sum = expected[3]
            expected_invalid = expected[4]

        var first_count = run_station(ctx)
        var first_temperature_sum = temperature_sum(ctx)
        var first_dense_sum = dense_sum(ctx)
        var first_dense_sq_sum = dense_sq_sum(ctx)
        var first_invalid = invalid_count(ctx)
        if first_count == FAILURE_COUNT:
            report_error(ctx)
            slot_to_dense.free()
            destroy(ctx)
            mapped.close()
            external_call["exit", NoneType](Int32(1))
        print(
            "STATION_FIRST_MS,",
            Float64(run_wall_ns(ctx)) / 1_000_000.0,
            ",GPU_DEVICE_MS,",
            Float64(gpu_ns(ctx)) / 1_000_000.0,
            ",ROWS,",
            first_count,
            ",TEMP_SUM,",
            first_temperature_sum,
            ",DENSE_SUM,",
            first_dense_sum,
            ",DENSE_SQ_SUM,",
            first_dense_sq_sum,
            ",INVALID,",
            first_invalid,
        )

        if not cpu_first:
            cpu_started = perf_counter_ns()
            var expected = index_stations_simd(
                mapped.ptr, slot_to_dense, mapped.size
            )
            cpu_finished = perf_counter_ns()
            expected_count = expected[0]
            expected_temperature_sum = expected[1]
            expected_dense_sum = expected[2]
            expected_dense_sq_sum = expected[3]
            expected_invalid = expected[4]
        if (
            first_count != UInt64(expected_count)
            or first_temperature_sum != expected_temperature_sum
            or first_dense_sum != expected_dense_sum
            or first_dense_sq_sum != expected_dense_sq_sum
            or first_invalid != expected_invalid
        ):
            print("ERROR: station index result does not match CPU oracle")
            print(
                "CPU:",
                expected_count,
                expected_temperature_sum,
                expected_dense_sum,
                expected_dense_sq_sum,
                expected_invalid,
            )
            print(
                "GPU:",
                first_count,
                first_temperature_sum,
                first_dense_sum,
                first_dense_sq_sum,
                first_invalid,
            )
            slot_to_dense.free()
            destroy(ctx)
            mapped.close()
            external_call["exit", NoneType](Int32(1))

        print("Station correctness: PASS")
        print(
            "CPU_STATION_REFERENCE_MS,",
            Float64(cpu_finished - cpu_started) / 1_000_000.0,
        )

        for sample in range(WARM_RUNS):
            var actual_count = run_station(ctx)
            var actual_temperature_sum = temperature_sum(ctx)
            var actual_dense_sum = dense_sum(ctx)
            var actual_dense_sq_sum = dense_sq_sum(ctx)
            var actual_invalid = invalid_count(ctx)
            if actual_count == FAILURE_COUNT:
                report_error(ctx)
                slot_to_dense.free()
                destroy(ctx)
                mapped.close()
                external_call["exit", NoneType](Int32(1))
            if (
                actual_count != UInt64(expected_count)
                or actual_temperature_sum != expected_temperature_sum
                or actual_dense_sum != expected_dense_sum
                or actual_dense_sq_sum != expected_dense_sq_sum
                or actual_invalid != expected_invalid
            ):
                print("ERROR: warm station result changed", sample)
                slot_to_dense.free()
                destroy(ctx)
                mapped.close()
                external_call["exit", NoneType](Int32(1))
            print(
                "STATION_WARM_MS,",
                sample + 1,
                ",",
                Float64(run_wall_ns(ctx)) / 1_000_000.0,
                ",GPU_DEVICE_MS,",
                Float64(gpu_ns(ctx)) / 1_000_000.0,
                ",ROWS,",
                actual_count,
                ",TEMP_SUM,",
                actual_temperature_sum,
                ",DENSE_SUM,",
                actual_dense_sum,
                ",DENSE_SQ_SUM,",
                actual_dense_sq_sum,
                ",INVALID,",
                actual_invalid,
            )

        slot_to_dense.free()
        destroy(ctx)
        mapped.close()
        return

    if temperature_mode:
        var cpu_started = 0
        var cpu_finished = 0
        var expected_count = 0
        var expected_sum = Int64(0)
        if cpu_first:
            cpu_started = perf_counter_ns()
            var expected = parse_temperatures_simd(mapped.ptr, mapped.size)
            cpu_finished = perf_counter_ns()
            expected_count = expected[0]
            expected_sum = expected[1]

        var first_count = run_temperature(ctx)
        var first_sum = temperature_sum(ctx)
        if first_count == FAILURE_COUNT:
            report_error(ctx)
            destroy(ctx)
            mapped.close()
            external_call["exit", NoneType](Int32(1))
        print(
            "TEMPERATURE_FIRST_MS,",
            Float64(run_wall_ns(ctx)) / 1_000_000.0,
            ",GPU_DEVICE_MS,",
            Float64(gpu_ns(ctx)) / 1_000_000.0,
            ",ROWS,",
            first_count,
            ",SUM,",
            first_sum,
        )

        if not cpu_first:
            cpu_started = perf_counter_ns()
            var expected = parse_temperatures_simd(mapped.ptr, mapped.size)
            cpu_finished = perf_counter_ns()
            expected_count = expected[0]
            expected_sum = expected[1]
        if (
            first_count != UInt64(expected_count)
            or first_sum != expected_sum
        ):
            print(
                "ERROR: temperature mismatch; CPU rows/sum=",
                expected_count,
                "/",
                expected_sum,
                " GPU rows/sum=",
                first_count,
                "/",
                first_sum,
            )
            destroy(ctx)
            mapped.close()
            external_call["exit", NoneType](Int32(1))

        print(
            "Temperature correctness: PASS (",
            expected_count,
            " rows, sum ",
            expected_sum,
            ")",
        )
        print(
            "CPU_TEMPERATURE_REFERENCE_MS,",
            Float64(cpu_finished - cpu_started) / 1_000_000.0,
        )

        for sample in range(WARM_RUNS):
            var actual_count = run_temperature(ctx)
            var actual_sum = temperature_sum(ctx)
            if actual_count == FAILURE_COUNT:
                report_error(ctx)
                destroy(ctx)
                mapped.close()
                external_call["exit", NoneType](Int32(1))
            if (
                actual_count != UInt64(expected_count)
                or actual_sum != expected_sum
            ):
                print("ERROR: warm temperature result changed", sample)
                destroy(ctx)
                mapped.close()
                external_call["exit", NoneType](Int32(1))
            print(
                "TEMPERATURE_WARM_MS,",
                sample + 1,
                ",",
                Float64(run_wall_ns(ctx)) / 1_000_000.0,
                ",GPU_DEVICE_MS,",
                Float64(gpu_ns(ctx)) / 1_000_000.0,
                ",ROWS,",
                actual_count,
                ",SUM,",
                actual_sum,
            )

        destroy(ctx)
        mapped.close()
        return

    var cpu_started = 0
    var cpu_finished = 0
    var expected = Int64(0)
    if cpu_first:
        cpu_started = perf_counter_ns()
        expected = count_newlines_simd(mapped.ptr, mapped.size)
        cpu_finished = perf_counter_ns()

    # GPU-first retains file and GPU-VM first-touch costs. CPU-first separates
    # file residency from the first Metal access to the no-copy VM region.
    var first_count = run(ctx)
    if first_count == FAILURE_COUNT:
        report_error(ctx)
        destroy(ctx)
        mapped.close()
        external_call["exit", NoneType](Int32(1))
    print(
        "GPU_FIRST_MS,",
        Float64(run_wall_ns(ctx)) / 1_000_000.0,
        ",GPU_DEVICE_MS,",
        Float64(gpu_ns(ctx)) / 1_000_000.0,
        ",COUNT,",
        first_count,
    )

    if not cpu_first:
        cpu_started = perf_counter_ns()
        expected = count_newlines_simd(mapped.ptr, mapped.size)
        cpu_finished = perf_counter_ns()
    if first_count != UInt64(expected):
        print("ERROR: newline mismatch; CPU=", expected, " GPU=", first_count)
        destroy(ctx)
        mapped.close()
        external_call["exit", NoneType](Int32(1))

    print("Correctness: PASS (", expected, " newlines)")
    print(
        "CPU_REFERENCE_MS,",
        Float64(cpu_finished - cpu_started) / 1_000_000.0,
    )

    for sample in range(WARM_RUNS):
        var actual = run(ctx)
        if actual == FAILURE_COUNT:
            report_error(ctx)
            destroy(ctx)
            mapped.close()
            external_call["exit", NoneType](Int32(1))
        if actual != UInt64(expected):
            print("ERROR: warm GPU count changed on sample", sample)
            destroy(ctx)
            mapped.close()
            external_call["exit", NoneType](Int32(1))
        print(
            "GPU_WARM_MS,",
            sample + 1,
            ",",
            Float64(run_wall_ns(ctx)) / 1_000_000.0,
            ",GPU_DEVICE_MS,",
            Float64(gpu_ns(ctx)) / 1_000_000.0,
            ",COUNT,",
            actual,
        )

    # MTLBuffer must release before the mmap that backs it is unmapped.
    destroy(ctx)
    mapped.close()
