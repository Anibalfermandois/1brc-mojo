from std.memory import UnsafePointer
from std.sys.info import simd_width_of
from std.bit import count_trailing_zeros
from metrics import ParserTracker, ParserMetrics, EmptyParserMetrics, MapTracker
from perfect_hashmap import PerfectStationMap

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
    ptr: UnsafePointer[UInt8, MutExternalOrigin],
    name_start: Int,
    nl: Int,
    mut metrics: T,
) -> None:
    """Parse a single row [name_start, nl) and insert into the map."""
    var chunk8 = (ptr + (nl - 8)).bitcast[UInt64]().load()
    var c_frac = Int((chunk8 >> 56) & 0xFF) - 48
    var c_units = Int((chunk8 >> 40) & 0xFF) - 48
    var c4 = Int((chunk8 >> 32) & 0xFF)
    var c5 = Int((chunk8 >> 24) & 0xFF)

    var c5_is_semi = Int(c5 == ASCII_SEMI)
    var c4_is_semi = Int(c4 == ASCII_SEMI)
    var offset = 6 - c5_is_semi - (c4_is_semi * 2)
    var name_len = nl - offset - name_start

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
    ptr: UnsafePointer[UInt8, MutExternalOrigin],
    size: Int,
    mut metrics: T,
):
    comptime width = 16
    comptime nl_vec = SIMD[DType.uint8, width](ASCII_LF)

    var i = 0
    var row_start = 0

    while i + width <= size:
        comptime if T.ACTIVE:
            metrics.record_simd_iteration()

        var chunk = ptr.load[width=width](i)
        var mask: SIMD[DType.bool, width] = chunk.eq(nl_vec)

        if mask.reduce_or():
            comptime if T.ACTIVE:
                metrics.record_simd_hit()
            comptime if width == 16:
                comptime u16_powers = SIMD[DType.uint16, 16](
                    1,
                    2,
                    4,
                    8,
                    16,
                    32,
                    64,
                    128,
                    256,
                    512,
                    1024,
                    2048,
                    4096,
                    8192,
                    16384,
                    32768,
                )
                var final_mask = Int(
                    (mask.cast[DType.uint16]() * u16_powers).reduce_add()
                )

                while final_mask != 0:
                    var bit_idx = Int(count_trailing_zeros(final_mask))
                    var nl = i + bit_idx
                    parse_row(map, ptr, row_start, nl, metrics)
                    row_start = nl + 1
                    final_mask &= final_mask - 1
                    comptime if T.ACTIVE:
                        metrics.record_row_simd()
            else:
                comptime for k in range(width):
                    if mask[k]:
                        var nl = i + k
                        parse_row(map, ptr, row_start, nl, metrics)
                        row_start = nl + 1
                        comptime if T.ACTIVE:
                            metrics.record_row_simd()
        else:
            comptime if T.ACTIVE:
                var s = String("")
                for k in range(width):
                    var c = ptr[i + k]
                    if c < 32 or c > 126:
                        s += "."
                    else:
                        s += chr(Int(c))
                metrics.record_missed_block(s)

        i += width

    while i < size:
        if ptr[i] == 10:
            parse_row(map, ptr, row_start, i, metrics)
            row_start = i + 1
            comptime if T.ACTIVE:
                metrics.record_row_tail()
        i += 1
