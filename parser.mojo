from std.memory import UnsafePointer
from std.sys.info import simd_width_of  # renamed from simdwidthof in Mojo 0.26
from perfect_hashmap import PerfectStationMap

comptime ASCII_LF = 10
comptime ASCII_CR = 13
comptime ASCII_SEMI = 59
comptime ASCII_DOT = 46
comptime ASCII_DASH = 45


@always_inline
fn parse_row[
    TRACK_METRICS: Bool = False
](
    mut map: PerfectStationMap[TRACK_METRICS=TRACK_METRICS],
    ptr: UnsafePointer[UInt8, MutExternalOrigin],
    name_start: Int,
    nl: Int,
) -> None:
    """Parse a single row [name_start, nl) and insert into the map."""
    # Clean out \r if present (Windows line endings)
    var end_idx = nl
    if ptr[nl - 1] == ASCII_CR:
        end_idx = nl - 1

    # --- Parse temperature backwards ---
    # Format is: [-]?[0-9][0-9]?\.[0-9]
    var c_frac = Int(ptr[end_idx - 1]) - 48
    # ptr[end_idx - 2] is always '.'
    var c_units = Int(ptr[end_idx - 3]) - 48
    var c4 = Int(ptr[end_idx - 4])
    var c5 = Int(ptr[end_idx - 5])

    # Branchless length calculation
    var c5_is_semi = Int(c5 == ASCII_SEMI)
    var c4_is_semi = Int(c4 == ASCII_SEMI)
    var offset = 6 - c5_is_semi - (c4_is_semi * 2)
    var name_len = end_idx - offset - name_start

    # Branchless value calculation
    var c4_val = c4 & 0x0F
    var has_tens = Int(c4_val <= 9)
    var tens = c4_val * has_tens

    var is_neg = Int(c4 == ASCII_DASH) | Int(c5 == ASCII_DASH)

    var temp_val = (tens * 100) + (c_units * 10) + c_frac
    var sign_mul = 1 - (is_neg * 2)
    temp_val *= sign_mul

    map.update_or_insert(ptr + name_start, name_len, temp_val)


fn parse_chunk[
    TRACK_METRICS: Bool = False
](
    mut map: PerfectStationMap[TRACK_METRICS=TRACK_METRICS],
    ptr: UnsafePointer[UInt8, MutExternalOrigin],
    size: Int,
):
    comptime width = simd_width_of[DType.uint8]()
    var nl_vec = SIMD[DType.uint8, width](ASCII_LF)
    var i = 0
    var row_start = 0

    # ── SIMD phase: process `width` bytes per iteration ──────────────
    # Each SIMD load covers `width` bytes and finds ALL newlines in the
    # window in one comparison — eliminating per-row find_newline calls.
    while i + width <= size:
        var chunk = ptr.load[width=width](i)
        var mask = chunk.eq(nl_vec)  # SIMD[DType.bool, width]

        if mask.reduce_or():
            # Compile-time unrolled scan over each lane
            comptime for k in range(width):
                if mask[k]:
                    var nl = i + k
                    parse_row[TRACK_METRICS](map, ptr, row_start, nl)
                    row_start = nl + 1

        i += width

    # ── Scalar tail: handle any remaining bytes < width ───────────────
    while i < size:
        if ptr[i] == 10:
            parse_row[TRACK_METRICS](map, ptr, row_start, i)
            row_start = i + 1
        i += 1
