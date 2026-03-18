from std.memory import UnsafePointer
from std.sys.info import simd_width_of
from std.bit import count_trailing_zeros
from perfect_hashmap import PerfectStationMap

@fieldwise_init
struct ParserMetrics(Copyable, Movable):
    var simd_iterations: Int
    var simd_hits: Int
    var rows_simd: Int
    var rows_tail: Int

    def __init__(out self):
        self.simd_iterations = 0
        self.simd_hits = 0
        self.rows_simd = 0
        self.rows_tail = 0

    def __init__(out self, *, copy: Self):
        self.simd_iterations = copy.simd_iterations
        self.simd_hits = copy.simd_hits
        self.rows_simd = copy.rows_simd
        self.rows_tail = copy.rows_tail

    def __init__(out self, *, deinit take: Self):
        self.simd_iterations = take.simd_iterations
        self.simd_hits = take.simd_hits
        self.rows_simd = take.rows_simd
        self.rows_tail = take.rows_tail

comptime ASCII_LF = 10
comptime ASCII_CR = 13
comptime ASCII_SEMI = 59
comptime ASCII_DOT = 46
comptime ASCII_DASH = 45


@always_inline
def parse_row[
    TRACK_METRICS: Bool = False
](
    mut map: PerfectStationMap[TRACK_METRICS=TRACK_METRICS],
    ptr: UnsafePointer[UInt8, MutExternalOrigin],
    name_start: Int,
    nl: Int,
) -> None:
    """Parse a single row [name_start, nl) and insert into the map."""
    # --- Parse temperature backwards via a single 8-byte load ---
    # Assumes Unix line endings (no \r) and nl >= 8 (safe for all valid
    # 1BRC rows: min row is "abc;9.9\n" = 8 bytes, so nl >= name_start+7,
    # and name_start >= 1 for all rows except possibly the first in the file).
    # Format: [-]?[0-9][0-9]?\.[0-9]
    var chunk8  = (ptr + (nl - 8)).bitcast[UInt64]().load()
    var c_frac  = Int((chunk8 >> 56) & 0xFF) - 48  # ptr[nl-1]: fractional digit
    var c_units = Int((chunk8 >> 40) & 0xFF) - 48  # ptr[nl-3]: units digit
    var c4      = Int((chunk8 >> 32) & 0xFF)        # ptr[nl-4]: tens | '-' | ';'
    var c5      = Int((chunk8 >> 24) & 0xFF)        # ptr[nl-5]: '-' | ';' | name

    # Branchless length calculation
    var c5_is_semi = Int(c5 == ASCII_SEMI)
    var c4_is_semi = Int(c4 == ASCII_SEMI)
    var offset = 6 - c5_is_semi - (c4_is_semi * 2)
    var name_len = nl - offset - name_start

    # Branchless value calculation
    var c4_val = c4 & 0x0F
    var has_tens = Int(c4_val <= 9)
    var tens = c4_val * has_tens

    var is_neg = Int(c4 == ASCII_DASH) | Int(c5 == ASCII_DASH)

    var temp_val = (tens * 100) + (c_units * 10) + c_frac
    var sign_mul = 1 - (is_neg * 2)
    temp_val *= sign_mul

    map.update_or_insert(ptr + name_start, name_len, temp_val)


def parse_chunk[
    TRACK_METRICS: Bool = False
](
    mut map: PerfectStationMap[TRACK_METRICS=TRACK_METRICS],
    ptr: UnsafePointer[UInt8, MutExternalOrigin],
    size: Int,
    mut metrics: ParserMetrics,
):
    comptime width = 16
    # Compile-time constants: baked into the binary as immediates, never
    # re-initialized at runtime regardless of loop iteration count.
    comptime nl_vec = SIMD[DType.uint8, width](ASCII_LF)

    var i = 0
    var row_start = 0

    # ── SIMD phase: process `width` bytes per iteration ──────────────
    # Each SIMD load covers `width` bytes and finds ALL newlines in the
    # window in one comparison — eliminating per-row find_newline calls.
    while i + width <= size:
        comptime if TRACK_METRICS:
            metrics.simd_iterations += 1

        var chunk = ptr.load[width=width](i)
        var mask: SIMD[DType.bool, width] = chunk.eq(nl_vec)

        if mask.reduce_or():
            comptime if TRACK_METRICS:
                metrics.simd_hits += 1
            comptime if width == 16:
                comptime u16_powers = SIMD[DType.uint16, 16](1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768)
                var final_mask = Int((mask.cast[DType.uint16]() * u16_powers).reduce_add())

                while final_mask != 0:
                    var bit_idx = Int(count_trailing_zeros(final_mask))
                    var nl = i + bit_idx
                    parse_row[TRACK_METRICS](map, ptr, row_start, nl)
                    row_start = nl + 1
                    final_mask &= final_mask - 1
                    comptime if TRACK_METRICS:
                        metrics.rows_simd += 1
            else:
                # Compile-time unrolled scan over each lane
                comptime for k in range(width):
                    if mask[k]:
                        var nl = i + k
                        parse_row[TRACK_METRICS](map, ptr, row_start, nl)
                        row_start = nl + 1
                        comptime if TRACK_METRICS:
                            metrics.rows_simd += 1

        i += width

    # ── Scalar tail: handle any remaining bytes < width ───────────────
    while i < size:
        if ptr[i] == 10:
            parse_row[TRACK_METRICS](map, ptr, row_start, i)
            row_start = i + 1
            comptime if TRACK_METRICS:
                metrics.rows_tail += 1
        i += 1
