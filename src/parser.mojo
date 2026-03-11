from std.memory import UnsafePointer
from std.sys.info import simd_width_of  # renamed from simdwidthof in Mojo 0.26
from perfect_hashmap import PerfectStationMap
from std.sys.intrinsics import llvm_intrinsic

@fieldwise_init
struct ParserMetrics(Copyable, Movable):
    var simd_iterations: Int
    var simd_hits: Int
    var rows_simd: Int
    var rows_tail: Int

    fn __init__(out self):
        self.simd_iterations = 0
        self.simd_hits = 0
        self.rows_simd = 0
        self.rows_tail = 0

    fn __copyinit__(out self, copy: Self):
        self.simd_iterations = copy.simd_iterations
        self.simd_hits = copy.simd_hits
        self.rows_simd = copy.rows_simd
        self.rows_tail = copy.rows_tail

    fn __moveinit__(out self, deinit take: Self):
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
    var c_frac: Int
    var c_units: Int
    var c4: Int
    var c5: Int

    if end_idx >= 8:
        var chunk8 = (ptr + (end_idx - 8)).bitcast[UInt64]().load()
        c_frac = Int((chunk8 >> 56) & 0xFF) - 48
        c_units = Int((chunk8 >> 40) & 0xFF) - 48
        c4 = Int((chunk8 >> 32) & 0xFF)
        c5 = Int((chunk8 >> 24) & 0xFF)
    else:
        c_frac = Int(ptr[end_idx - 1]) - 48
        c_units = Int(ptr[end_idx - 3]) - 48
        c4 = Int(ptr[end_idx - 4])
        c5 = Int(ptr[end_idx - 5])

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
    mut metrics: ParserMetrics,
):
    comptime width = 16
    var nl_vec = SIMD[DType.uint8, width](ASCII_LF)
    var i = 0
    var row_start = 0

    # ── SIMD phase: process `width` bytes per iteration ──────────────
    # Each SIMD load covers `width` bytes and finds ALL newlines in the
    # window in one comparison — eliminating per-row find_newline calls.
    while i + width <= size:
        comptime if TRACK_METRICS:
            metrics.simd_iterations += 1
            
        var chunk = ptr.load[width=width](i)
        var mask = chunk.eq(nl_vec)  # SIMD[DType.bool, width]

        if mask.reduce_or():
            comptime if TRACK_METRICS:
                metrics.simd_hits += 1
                
            comptime if width == 16:
                var powers = SIMD[DType.uint8, 16](1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128)
                var mask_u8 = mask.cast[DType.uint8]()
                var weighted = mask_u8 * powers
                var low = Int(weighted.slice[8, offset=0]().reduce_add())
                var high = Int(weighted.slice[8, offset=8]().reduce_add())
                
                var final_mask = low | (high << 8)
                
                while final_mask != 0:
                    var bit_idx = Int(llvm_intrinsic["llvm.cttz.i16", Int16](Int16(final_mask), False))
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
