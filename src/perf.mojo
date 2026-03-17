"""perf.mojo — 1BRC Unified Performance & Analysis Tool

Usage:
    mojo run perf.mojo [filename] [--analyze]

This is the unified performance and analysis tool. If --analyze is passed,
it runs with TRACK_METRICS=True, performing collision checks and deep
metric tracking with minimal overhead. Otherwise, it runs at full speed.
"""

from std.sys import argv
from std.sys.info import num_logical_cores
from std.time import perf_counter_ns
from perfect_hashmap import PerfectStationMap, MapMetrics
from mmap import MappedFile, MADV_WILLNEED, MADV_SEQUENTIAL, MADV_DONTNEED, madvise_range
from parser import parse_chunk, ParserMetrics
from std.algorithm import parallelize
from profiler import Profiler

# ── Helpers for Analysis Mode ────────────────────────────────────────────────

def pad_right(s: String, width: Int) -> String:
    var out = s
    for _ in range(width - len(s)):
        out += " "
    return out

def pad_left(s: String, width: Int) -> String:
    var out = ""
    for _ in range(width - len(s)):
        out += " "
    return out + s

def fmt_float2(v: Float64) -> String:
    var i = Int(v)
    var frac = Int((v - Float64(i)) * 100.0)
    if frac < 0:
        frac = -frac
    var frac_str = String(frac)
    if frac < 10:
        frac_str = "0" + frac_str
    return String(i) + "." + frac_str

def divot_line(widths: List[Int]):
    var line = "+"
    for i in range(len(widths)):
        for _ in range(widths[i] + 2):
            line += "-"
        line += "+"
    print(line)

def print_header(cols: List[String], widths: List[Int]):
    divot_line(widths)
    var row = "|"
    for i in range(len(cols)):
        row += " " + pad_right(cols[i], widths[i]) + " |"
    print(row)
    divot_line(widths)

def print_row(cells: List[String], widths: List[Int]):
    var row = "|"
    for i in range(len(cells)):
        row += " " + pad_left(cells[i], widths[i]) + " |"
    print(row)

# ── Per-thread result holder ──────────────────────────────────────────────────
struct ThreadResult(Copyable, ImplicitlyCopyable, Movable):
    var tid: Int
    var elapsed_ns: Int
    var metrics: MapMetrics
    var parser_metrics: ParserMetrics

    def __init__(out self):
        self.tid = 0
        self.elapsed_ns = 0
        self.metrics = MapMetrics()
        self.parser_metrics = ParserMetrics()

    def __init__(out self, *, copy: Self):
        self.tid = copy.tid
        self.elapsed_ns = copy.elapsed_ns
        self.metrics = copy.metrics.copy()
        self.parser_metrics = copy.parser_metrics.copy()

    def __init__(out self, *, deinit take: Self):
        self.tid = take.tid
        self.elapsed_ns = take.elapsed_ns
        self.metrics = take.metrics^
        self.parser_metrics = take.parser_metrics^


def run_pipeline[TRACK_METRICS: Bool](filename: String) raises:
    var prof = Profiler()
    var mode_str = "ANALYSIS"
    comptime if not TRACK_METRICS:
        mode_str = "BENCHMARK"

    print("=" * 60)
    print("1BRC Unified Tool [Mode: ", mode_str, "] —", filename)
    print("=" * 60)

    # ══ Phase 1: Mmap Setup ════════════════════════════════════════
    prof.tic("I/O Setup (mmap)")
    var mapped = MappedFile(filename)
    var ptr = mapped.ptr
    var size = mapped.size

    # Size-based I/O strategy:
    #   < 8 GB  → MADV_WILLNEED: bulk-preload into RAM (fast sequential NVMe
    #             read first, then parse entirely from RAM at full speed).
    #   ≥ 8 GB  → MADV_SEQUENTIAL: stream pages on demand. Each thread then
    #             calls MADV_DONTNEED after its chunk to release physical pages,
    #             preventing RAM thrash on files larger than available RAM (1B=13GB).
    comptime STREAMING_THRESHOLD = 8 * 1024 * 1024 * 1024  # 8 GB
    var use_streaming = size >= STREAMING_THRESHOLD
    if use_streaming:
        mapped.advise(MADV_SEQUENTIAL)
    else:
        mapped.advise(MADV_WILLNEED)
    prof.toc("I/O Setup (mmap)")

    # ══ Phase 2: Row Count Estimation ══════════════════════════════
    var row_count = 0
    if filename.find("1b") != -1:
        row_count = 1_000_000_000
    elif filename.find("600m") != -1:
        row_count = 600_019_848
    elif filename.find("300m") != -1:
        row_count = 300_008_620
    elif filename.find("100m") != -1:
        row_count = 100_000_000
    elif filename.find("1m") != -1:
        row_count = 1_000_000
    elif filename.find("10k") != -1:
        row_count = 10_000

    # ══ Phase 3: Full Parallel Pipeline ════════════════════════════
    var num_threads = num_logical_cores()
    var chunk_size = size // num_threads

    prof.tic("Chunk Boundary Calculation")
    var chunk_starts = List[Int](capacity=num_threads + 1)
    chunk_starts.append(0)
    for i in range(1, num_threads):
        var start_guess = i * chunk_size
        while start_guess > 0 and ptr[start_guess - 1] != 10:
            start_guess -= 1
        chunk_starts.append(start_guess)
    chunk_starts.append(size)
    prof.toc("Chunk Boundary Calculation")

    prof.tic("Map Initialization")
    var maps = List[PerfectStationMap[TRACK_METRICS=TRACK_METRICS]](capacity=num_threads)
    var results = List[ThreadResult](capacity=num_threads)
    for _ in range(num_threads):
        maps.append(PerfectStationMap[TRACK_METRICS=TRACK_METRICS]())
        results.append(ThreadResult())
    prof.toc("Map Initialization")

    prof.tic("Parallel Parse")

    @parameter
    fn process_chunk[STREAMING: Bool](tid: Int):
        var start = chunk_starts[tid]
        var end = chunk_starts[tid + 1]
        var chunk_ptr = ptr + start
        var chunk_len = end - start

        var maps_ptr = maps.unsafe_ptr()
        var parser_metrics = ParserMetrics()

        var t0 = perf_counter_ns()
        parse_chunk[TRACK_METRICS](maps_ptr[tid], chunk_ptr, chunk_len, parser_metrics)
        var t1 = perf_counter_ns()

        # For files > RAM: release processed pages so the OS can page in
        # upcoming chunks without thrashing. Not needed for small files
        # (WILLNEED already loaded them into RAM, DONTNEED would evict them).
        comptime if STREAMING:
            madvise_range(chunk_ptr, chunk_len, MADV_DONTNEED)

        var res_ptr = results.unsafe_ptr()
        res_ptr[tid].tid = tid
        res_ptr[tid].elapsed_ns = Int(t1 - t0)
        comptime if TRACK_METRICS:
            res_ptr[tid].metrics = maps_ptr[tid].metrics.copy()
            res_ptr[tid].parser_metrics = parser_metrics.copy()

    if use_streaming:
        parallelize[process_chunk[True]](num_threads)
    else:
        parallelize[process_chunk[False]](num_threads)
    prof.toc("Parallel Parse")

    prof.tic("Merge Maps")
    var final_map = PerfectStationMap[TRACK_METRICS=TRACK_METRICS]()
    for i in range(num_threads):
        final_map.merge_from(maps[i])
    prof.toc("Merge Maps")
    print("Final Map Size:", final_map.size)

    # ══ Summary & Analysis Output ══════════════════════════════════
    prof.report()

    var parse_ns = prof._totals["Parallel Parse"]
    var parse_s = Float64(parse_ns) / 1_000_000_000.0

    comptime if not TRACK_METRICS:
        if row_count > 0:
            var tput = Float64(row_count) / parse_s / 1_000_000.0
            print("  Throughput (Parse stage): ", prof._fmt_float(tput), " M rows/s")

            print("\n  [Hardware Bottleneck Analysis]")
            if tput > 300.0:
                print("  Status: Excellent! Running entirely from Physical RAM/OS Cache.")
            else:
                print("  Status: WARNING! Hardware I/O Limit Hit.")
                print("  The dataset size exceeds available dedicated RAM caching.")
                print("  Threads are heavily blocked on NVMe/OS Page Faults instead of CPU parsing.")
    else:
        print("\n── Deep Analysis Results ──────────────────────────────────────────────")
        var agg_lookups = 0
        var agg_probes = 0
        var max_chain = 0
        var agg_simd_iters = 0
        var agg_simd_hits = 0
        var agg_simd_rows = 0
        var agg_tail_rows = 0

        var slowest_ns = 0
        var fastest_ns = Int.MAX

        for t in range(num_threads):
            var r = results.unsafe_ptr()[t]
            agg_lookups += r.metrics.total_lookups
            agg_probes += r.metrics.total_probes
            if r.metrics.max_probe_run > max_chain:
                max_chain = r.metrics.max_probe_run

            agg_simd_iters += r.parser_metrics.simd_iterations
            agg_simd_hits += r.parser_metrics.simd_hits
            agg_simd_rows += r.parser_metrics.rows_simd
            agg_tail_rows += r.parser_metrics.rows_tail

            if r.elapsed_ns > slowest_ns: slowest_ns = r.elapsed_ns
            if r.elapsed_ns < fastest_ns: fastest_ns = r.elapsed_ns

        var skew_pct = Float64(slowest_ns - fastest_ns) / Float64(max(slowest_ns, 1)) * 100.0
        var actual_rows = agg_simd_rows + agg_tail_rows
        var actual_tput = Float64(actual_rows) / parse_s / 1_000_000.0

        print("  Actual Parsed Rows: ", actual_rows)
        print("  Actual Throughput:  ", fmt_float2(actual_tput), " M rows/s")
        print("\n── Threading Skew ───────────────────────────────────────────────────")
        print("  Fastest thread: ", fmt_float2(Float64(fastest_ns) / 1e6), "ms")
        print("  Slowest thread: ", fmt_float2(Float64(slowest_ns) / 1e6), "ms")
        print("  Thread skew:    ", fmt_float2(skew_pct), "% (0% = perfect)")

        print("\n── Parser Metrics (`parse_chunk`) ───────────────────────────────────")
        print("  SIMD Iterations:", agg_simd_iters)
        var hit_pct = Float64(agg_simd_hits) / max(Float64(agg_simd_iters), 1.0) * 100.0
        print("  SIMD Hits:      ", agg_simd_hits, " (", fmt_float2(hit_pct), "% of 16-byte blocks had a newline)")
        print("  Rows via SIMD:  ", agg_simd_rows)
        print("  Rows via Tail:  ", agg_tail_rows)

        print("\n── Perfect Hashmap Collision Verification ───────────────────────────")
        print("  Total Lookups:  ", agg_lookups)
        print("  Unique Stations:", final_map.size)
        if agg_probes > 0:
            print("  [!] WARNING: Collisions detected! Total Probes:", agg_probes)
            print("  This means your PerfectStationMap multiplier/shift failed for this dataset.")
        else:
            print("  [+] SUCCESS: Zero collisions detected! 100% perfect hash.")

    mapped.close()

def main() raises:
    var args = argv()
    var filename = "measurements_100k.txt" # fallback
    var index = 1
    var analyze_mode = False

    while index < len(args):
        if args[index] == "--analyze" or args[index] == "-a":
            analyze_mode = True
        else:
            filename = args[index]
        index += 1

    if analyze_mode:
        run_pipeline[True](filename)
    else:
        run_pipeline[False](filename)
