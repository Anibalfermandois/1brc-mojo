from std.memory import UnsafePointer, bitcast
from std.sys.info import simd_width_of
from std.bit import count_trailing_zeros
from std.sys.intrinsics import likely, unlikely, assume, expect
from misc.metrics import (
    ParserTracker,
    ParserMetrics,
    EmptyParserMetrics,
    MapTracker,
)
from engine.perfect_hashmap import PerfectStationMap


comptime ASCII_LF = 10
comptime ASCII_CR = 13
comptime ASCII_SEMI = 59
comptime ASCII_DOT = 46
comptime ASCII_DASH = 45


@always_inline
def parse_row[
    T: ParserTracker,
    MAP_T: MapTracker,
](
    mut map: PerfectStationMap[MAP_TRACKER=MAP_T],
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    name_start: Int,
    nl: Int,
    mut metrics: T,
    bounded_load: Bool = False,
) -> None:
    """Parse a single row [name_start, nl) and insert into the map."""
    chunk8 = UInt64(0)
    if bounded_load:
        # The first legal row can place its newline at byte 7, so an 8-byte
        # backward load would begin before the chunk. Reconstruct only the
        # four bytes the temperature parser consumes.
        chunk8 |= UInt64(ptr[nl - 5]) << 24
        chunk8 |= UInt64(ptr[nl - 4]) << 32
        chunk8 |= UInt64(ptr[nl - 3]) << 40
        chunk8 |= UInt64(ptr[nl - 1]) << 56
    else:
        chunk8 = (ptr + (nl - 8)).bitcast[UInt64]().load[alignment=1]()
    c_frac = Int((chunk8 >> 56) & 0x0F)
    c_units = Int((chunk8 >> 40) & 0x0F)
    c4 = Int((chunk8 >> 32) & 0xFF)
    c5 = Int((chunk8 >> 24) & 0xFF)

    c5_is_semi = Int(c5 == ASCII_SEMI)
    c4_is_semi = Int(c4 == ASCII_SEMI)
    offset = 6 - c5_is_semi - (c4_is_semi * 2)
    name_len = nl - offset - name_start
    assume(name_len > 0)
    assume(name_len < 128)

    c4_val = c4 & 0x0F
    has_tens = Int(c4_val <= 9)
    tens = c4_val * has_tens

    is_neg = Int(c4 == ASCII_DASH) | Int(c5 == ASCII_DASH)

    temp_val = (tens * 100) + (c_units * 10) + c_frac
    sign_mul = 1 - (is_neg * 2)
    temp_val *= sign_mul

    map.update_or_insert(ptr + name_start, name_len, temp_val)
    comptime if T.ACTIVE:
        metrics.record_name(name_len)


def parse_chunk[
    T: ParserTracker,
    MAP_T: MapTracker,
](
    mut map: PerfectStationMap[MAP_TRACKER=MAP_T],
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    size: Int,
    mut metrics: T,
):
    comptime width = 16
    comptime nl_vec = SIMD[DType.uint8, width](ASCII_LF)

    # Peel one row per chunk so the backward temperature load is always
    # contained within the chunk. Seven is the earliest legal newline:
    # three-byte station, semicolon, and three-byte temperature.
    if size <= 7:
        return
    first_nl = 7
    while first_nl < size and ptr[first_nl] != ASCII_LF:
        first_nl += 1
    if first_nl == size:
        return
    parse_row(map, ptr, 0, first_nl, metrics, bounded_load=True)
    comptime if T.ACTIVE:
        metrics.record_row_tail()

    i = first_nl + 1
    row_start = i
    while likely(i + 16 <= size):
        comptime if T.ACTIVE:
            metrics.record_simd_iteration()
        chunk = ptr.load[width=16](i)
        mask = chunk.eq(nl_vec)

        if likely(mask.reduce_or()):
            comptime if T.ACTIVE:
                metrics.record_simd_hit()
            bytes = mask.cast[DType.uint8]() & 1
            u64 = bitcast[DType.uint64, 2](bytes)
            res0 = (u64[0] * 0x0102040810204080) >> 56
            res1 = (u64[1] * 0x0102040810204080) >> 56
            final_mask = Int(res0) | (Int(res1) << 8)

            comptime if T.ACTIVE:
                if (final_mask & (final_mask - 1)) == 0:
                    metrics.record_single_newline_block()
                else:
                    metrics.record_multi_newline_block()

            while final_mask != 0:
                bit_idx = Int(count_trailing_zeros(final_mask))
                nl = i + bit_idx
                parse_row(map, ptr, row_start, nl, metrics)
                row_start = nl + 1
                final_mask &= final_mask - 1
                comptime if T.ACTIVE:
                    metrics.record_row_simd()
        i += 16

    while i < size:
        if ptr[i] == 10:
            parse_row(map, ptr, row_start, i, metrics)
            row_start = i + 1
            comptime if T.ACTIVE:
                metrics.record_row_tail()
        i += 1
