"""
benchmark.mojo — 1BRC Parallel Profiler
Times the optimized mmap + parallel pipeline.

Usage: mojo run benchmark.mojo [filename]
"""

from std.sys import argv
from std.sys.info import simd_width_of, num_logical_cores
from std.ffi import external_call
from std.time import perf_counter_ns
from std.memory import UnsafePointer
from perfect_hashmap import PerfectStationMap
from mmap import MappedFile
from parser import parse_chunk
from std.algorithm import parallelize


fn ns_to_ms(ns: UInt) -> Float64:
    return Float64(Int(ns)) / 1_000_000.0


fn ns_to_s(ns: UInt) -> Float64:
    return Float64(Int(ns)) / 1_000_000_000.0


fn mrows(rows: Int, ns: UInt) -> Float64:
    if ns == 0:
        return 0.0
    return Float64(rows) / ns_to_s(ns) / 1_000_000.0


from profiler import Profiler


fn main() raises:
    var filename = "measurements_100m.txt"
    if len(argv()) > 1:
        filename = argv()[1]

    var prof = Profiler()
    print("=" * 60)
    print("1BRC Parallel Benchmark —", filename)
    print("=" * 60)

    # ══ Phase 1: Mmap Setup ════════════════════════════════════════
    prof.tic("I/O Setup (mmap)")
    var mapped = MappedFile(filename)
    from mmap import MADV_SEQUENTIAL

    mapped.advise(MADV_SEQUENTIAL)
    prof.toc("I/O Setup (mmap)")

    var ptr = mapped.ptr
    var size = mapped.size

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

    # ── 3a: Map init time ──────────────────────────────────────────
    prof.tic("Map Initialization")
    var maps = List[PerfectStationMap[TRACK_METRICS=False]](
        capacity=num_threads
    )
    for _ in range(num_threads):
        maps.append(PerfectStationMap[TRACK_METRICS=False]())
    prof.toc("Map Initialization")

    # ── 3b: Parse time ─────────────────────────────────────────────
    prof.tic("Parallel Parse")

    @parameter
    fn process_chunk(tid: Int):
        var start = chunk_starts[tid]
        var end = chunk_starts[tid + 1]
        var chunk_ptr = ptr + start
        var chunk_len = end - start

        var maps_ptr = maps.unsafe_ptr()
        parse_chunk(maps_ptr[tid], chunk_ptr, chunk_len)

    parallelize[process_chunk](num_threads)
    prof.toc("Parallel Parse")

    # ── 3c: Merge time ─────────────────────────────────────────────
    prof.tic("Merge Maps")
    var final_map = PerfectStationMap[TRACK_METRICS=False]()
    for i in range(num_threads):
        final_map.merge_from(maps[i])
    prof.toc("Merge Maps")

    # ── 3d: Sorting and Output (usually part of total but separated) ──
    prof.tic("Sort/Format Results")
    # final_map.print_sorted() # Optional: print for verification
    prof.toc("Sort/Format Results")

    # ══ Summary ════════════════════════════════════════════════════
    prof.report()

    if row_count > 0:
        # Calculate throughput using parse time (the most relevant metric)
        var parse_ns = prof._totals["Parallel Parse"]
        var parse_s = Float64(parse_ns) / 1_000_000_000.0
        var tput = Float64(row_count) / parse_s / 1_000_000.0
        print(
            "  Throughput (Parse stage): ", prof._fmt_float(tput), " M rows/s"
        )

    mapped.close()
