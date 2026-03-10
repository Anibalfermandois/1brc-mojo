"""analyze.mojo — Deep performance analysis for the 1BRC pipeline.

This is a DEVELOPMENT TOOL, not part of the production path.
Run with:
    mojo run analyze.mojo measurements_300m.txt

It enables TRACK_METRICS=True in FastStationMap, so every hashmap lookup
writes per-thread statistics. This has a small perf overhead, so do NOT use
it to measure throughput — use benchmark.mojo for that.

Metrics collected per thread:
  • elapsed_ns         — Wall-clock time the thread spent in parse_chunk
  • rows_processed     — Number of newlines parsed (≈ rows)
  • throughput_mrows   — Compute throughput in million rows/s for this thread
  • total_lookups      — Total update_or_insert calls
  • total_inserts      — New station slots created (first time a name is seen)
  • total_updates      — Updates to existing stations
  • total_probes       — Extra slots probed due to hash collisions
  • max_probe_run      — Worst single-lookup probe chain length (0 = no collision)
  • avg_probes         — total_probes / total_lookups (ideal: 0.00)
"""

from std.sys import argv
from std.sys.info import num_logical_cores
from std.time import perf_counter_ns
from std.memory import UnsafePointer
from perfect_hashmap import PerfectStationMap, MapMetrics
from parser import parse_chunk
from mmap import MappedFile, MADV_SEQUENTIAL
from std.algorithm import parallelize


# ── Per-thread result holder ──────────────────────────────────────────────────
struct ThreadResult(Copyable, Movable):
    var tid: Int
    var elapsed_ns: Int
    var rows_processed: Int
    var metrics: MapMetrics

    fn __init__(out self):
        self.tid = 0
        self.elapsed_ns = 0
        self.rows_processed = 0
        self.metrics = MapMetrics()

    fn __copyinit__(out self, copy: Self):
        self.tid = copy.tid
        self.elapsed_ns = copy.elapsed_ns
        self.rows_processed = copy.rows_processed
        self.metrics = copy.metrics.copy()

    fn __moveinit__(out self, deinit take: Self):
        self.tid = take.tid
        self.elapsed_ns = take.elapsed_ns
        self.rows_processed = take.rows_processed
        self.metrics = take.metrics^


# ── Helpers ───────────────────────────────────────────────────────────────────
fn pad_right(s: String, width: Int) -> String:
    var out = s
    for _ in range(width - len(s)):
        out += " "
    return out


fn pad_left(s: String, width: Int) -> String:
    var out = ""
    for _ in range(width - len(s)):
        out += " "
    return out + s


fn fmt_float2(v: Float64) -> String:
    var i = Int(v)
    var frac = Int((v - Float64(i)) * 100.0)
    if frac < 0:
        frac = -frac
    var frac_str = String(frac)
    if frac < 10:
        frac_str = "0" + frac_str
    return String(i) + "." + frac_str


fn divot_line(widths: List[Int]):
    var line = "+"
    for i in range(len(widths)):
        for _ in range(widths[i] + 2):
            line += "-"
        line += "+"
    print(line)


fn print_header(cols: List[String], widths: List[Int]):
    divot_line(widths)
    var row = "|"
    for i in range(len(cols)):
        row += " " + pad_right(cols[i], widths[i]) + " |"
    print(row)
    divot_line(widths)


fn print_row(cells: List[String], widths: List[Int]):
    var row = "|"
    for i in range(len(cells)):
        row += " " + pad_left(cells[i], widths[i]) + " |"
    print(row)


# ── Main ──────────────────────────────────────────────────────────────────────
fn main() raises:
    var args = argv()
    if len(args) < 2:
        print("Usage: mojo run analyze.mojo <measurements_file>")
        return

    var filename = args[1]
    var mapped = MappedFile(filename)
    _ = mapped.advise(MADV_SEQUENTIAL)

    var ptr = mapped.ptr
    var size = mapped.size
    var num_threads = num_logical_cores()

    print()
    print("╔══════════════════════════════════════════════════════════════╗")
    print("║       1BRC Deep Analysis — TRACK_METRICS=True                ║")
    print("╚══════════════════════════════════════════════════════════════╝")
    print("  File:    ", filename)
    print("  Size:    ", fmt_float2(Float64(size) / 1e9), "GB")
    print("  Threads: ", num_threads)
    print()

    # ── Chunk boundaries (align to newlines) ─────────────────────────────────
    var chunk_size = size // num_threads
    var chunk_starts = List[Int](capacity=num_threads + 1)
    chunk_starts.append(0)

    for t in range(1, num_threads):
        var pos = t * chunk_size
        while pos < size and ptr[pos] != 10:
            pos += 1
        chunk_starts.append(pos + 1)
    chunk_starts.append(size)

    # ── Per-thread results and maps ───────────────────────────────────────────
    var maps = List[PerfectStationMap[TRACK_METRICS=True]](capacity=num_threads)
    var results = List[ThreadResult](capacity=num_threads)
    for _ in range(num_threads):
        maps.append(PerfectStationMap[TRACK_METRICS=True]())
        results.append(ThreadResult())

    # ── Parallel parse with timing ────────────────────────────────────────────
    var t_start = perf_counter_ns()

    @parameter
    fn process_chunk(tid: Int):
        var start = chunk_starts[tid]
        var end = chunk_starts[tid + 1]
        var chunk_ptr = ptr + start
        var chunk_len = end - start

        var maps_ptr = maps.unsafe_ptr()
        var t0 = perf_counter_ns()
        parse_chunk[True](maps_ptr[tid], chunk_ptr, chunk_len)
        var t1 = perf_counter_ns()

        var res_ptr = results.unsafe_ptr()
        res_ptr[tid].tid = tid
        res_ptr[tid].elapsed_ns = Int(t1 - t0)
        res_ptr[tid].rows_processed = maps_ptr[tid].metrics.total_lookups
        res_ptr[tid].metrics = maps_ptr[tid].metrics.copy()

    parallelize[process_chunk](num_threads)

    var t_total = perf_counter_ns() - t_start

    # ── Merge results ─────────────────────────────────────────────────────────
    var global_map = PerfectStationMap[TRACK_METRICS=True]()
    for t in range(1, num_threads):
        global_map.merge_from(maps[t])

    # ── Per-thread table ──────────────────────────────────────────────────────
    var cols = List[String]()
    cols.append("Tid")
    cols.append("Elapsed (ms)")
    cols.append("Rows")
    cols.append("Tput (M/s)")
    cols.append("Lookups")
    cols.append("Inserts")
    cols.append("Updates")
    cols.append("TotProbes")
    cols.append("MaxChain")
    cols.append("AvgProbes")

    var widths = List[Int]()
    widths.append(4)
    widths.append(12)
    widths.append(11)
    widths.append(10)
    widths.append(10)
    widths.append(9)
    widths.append(9)
    widths.append(10)
    widths.append(9)
    widths.append(10)

    print_header(cols, widths)

    var slowest_ns = 0
    var fastest_ns = Int.MAX
    for t in range(num_threads):
        if results[t].elapsed_ns > slowest_ns:
            slowest_ns = results[t].elapsed_ns
        if results[t].elapsed_ns < fastest_ns:
            fastest_ns = results[t].elapsed_ns

    for t in range(num_threads):
        var r_ptr = results.unsafe_ptr() + t
        var elapsed_ms = Float64(r_ptr[].elapsed_ns) / 1e6
        var tput = (
            Float64(r_ptr[].metrics.total_lookups)
            / Float64(r_ptr[].elapsed_ns)
            * 1000.0
        )
        var avg_probes = Float64(r_ptr[].metrics.total_probes) / Float64(
            max(r_ptr[].metrics.total_lookups, 1)
        )

        var cells = List[String]()
        cells.append(String(r_ptr[].tid))
        cells.append(fmt_float2(elapsed_ms))
        cells.append(String(r_ptr[].metrics.total_lookups))
        cells.append(fmt_float2(tput))
        cells.append(String(r_ptr[].metrics.total_lookups))
        cells.append(String(r_ptr[].metrics.total_inserts))
        cells.append(String(r_ptr[].metrics.total_updates))
        cells.append(String(r_ptr[].metrics.total_probes))
        cells.append(String(r_ptr[].metrics.max_probe_run))
        cells.append(fmt_float2(avg_probes))
        print_row(cells, widths)

    divot_line(widths)

    # ── Summary analytics ──────────────────────────────────────────────────────
    var skew_pct = (
        Float64(slowest_ns - fastest_ns) / Float64(max(slowest_ns, 1)) * 100.0
    )

    # Aggregate collision stats across all threads
    var agg_lookups = 0
    var agg_probes = 0
    var agg_max_chain = 0
    for t in range(num_threads):
        agg_lookups += results[t].metrics.total_lookups
        agg_probes += results[t].metrics.total_probes
        if results[t].metrics.max_probe_run > agg_max_chain:
            agg_max_chain = results[t].metrics.max_probe_run

    var global_avg_probes = Float64(agg_probes) / Float64(max(agg_lookups, 1))
    var total_ms = Float64(t_total) / 1e6

    print()
    print("── Core Asymmetry ───────────────────────────────────────────────")
    print("  Fastest thread: ", fmt_float2(Float64(fastest_ns) / 1e6), "ms")
    print("  Slowest thread: ", fmt_float2(Float64(slowest_ns) / 1e6), "ms")
    print(
        "  Thread skew:    ",
        fmt_float2(skew_pct),
        "% (0% = perfect balance, >50% = P/E-core gap)",
    )
    print()
    print("── Hash Quality (per CAPACITY=16384, 413 stations, load=2.5%) ───")
    print(
        "  Total probes:   ",
        agg_probes,
        " (extra slot checks due to collisions)",
    )
    print(
        "  Global avg:     ",
        fmt_float2(global_avg_probes),
        " probes/lookup (ideal: 0.00)",
    )
    print(
        "  Worst chain:    ", agg_max_chain, " (worst single lookup probe run)"
    )
    print()
    print("── Overall ──────────────────────────────────────────────────────")
    print("  Wall time:      ", fmt_float2(total_ms), "ms")
    print("  Unique stations:", global_map.size)
    print()
