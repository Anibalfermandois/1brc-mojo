from std.memory import UnsafePointer, bitcast
from std.sys.info import simd_width_of
from std.bit import count_trailing_zeros
from std.sys.intrinsics import likely, unlikely, assume, expect
from misc.metrics import ParserTracker, ParserMetrics, EmptyParserMetrics, MapTracker
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
) -> None:
    """Parse a single row [name_start, nl) and insert into the map."""
    var chunk8 = (ptr + (nl - 8)).bitcast[UInt64]().load()
    var c_frac = Int((chunk8 >> 56) & 0x0F)
    var c_units = Int((chunk8 >> 40) & 0x0F)
    var c4 = Int((chunk8 >> 32) & 0xFF)
    var c5 = Int((chunk8 >> 24) & 0xFF)

    var c5_is_semi = Int(c5 == ASCII_SEMI)
    var c4_is_semi = Int(c4 == ASCII_SEMI)
    var offset = 6 - c5_is_semi - (c4_is_semi * 2)
    var name_len = nl - offset - name_start
    assume(name_len > 0)
    assume(name_len < 128)

    var c4_val = c4 & 0x0F
    var has_tens = Int(c4_val <= 9)
    var tens = c4_val * has_tens

    var is_neg = Int(c4 == ASCII_DASH) | Int(c5 == ASCII_DASH)

    var temp_val = (tens * 100) + (c_units * 10) + c_frac
    var sign_mul = 1 - (is_neg * 2)
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

    var i = 0
    var row_start = 0

    while likely(i + 16 <= size):
        comptime if T.ACTIVE:
            metrics.record_simd_iteration()
        var chunk = ptr.load[width=16](i)
        var mask = chunk.eq(nl_vec)

        if likely(mask.reduce_or()):
            comptime if T.ACTIVE:
                metrics.record_simd_hit()
            var bytes = mask.cast[DType.uint8]() & 1
            var u64 = bitcast[DType.uint64, 2](bytes)
            var res0 = (u64[0] * 0x0102040810204080) >> 56
            var res1 = (u64[1] * 0x0102040810204080) >> 56
            var final_mask = Int(res0) | (Int(res1) << 8)

            comptime if T.ACTIVE:
                if (final_mask & (final_mask - 1)) == 0:
                    metrics.record_single_newline_block()
                else:
                    metrics.record_multi_newline_block()

            while final_mask != 0:
                var bit_idx = Int(count_trailing_zeros(final_mask))
                var nl = i + bit_idx
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
