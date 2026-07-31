"""Run the 1BRC pipeline through the streaming path.

Usage:
    mojo run perf.mojo [filename] [--analyze]

This is the unified performance and analysis tool. If --analyze is passed,
it runs with TRACK_METRICS=True, performing collision checks and deep
metric tracking with minimal overhead. Otherwise, it runs at full speed.
"""

from std.sys import argv
from std.sys.info import num_logical_cores
from std.time import perf_counter_ns
from misc.metrics import (
    MapMetrics,
    EmptyMapMetrics,
    ParserMetrics,
    EmptyParserMetrics,
    MapTracker,
    ParserTracker,
)
from IO.mmap import MappedFile, MADV_WILLNEED
from engine.perfect_hashmap import PerfectStationMap
from engine.parser import parse_chunk
from analyzer import run_analysis
from IO.streaming import FileHandle, DoubleBufferedStream, find_first_newline
from std.ffi import external_call
from std.gpu.host import DeviceContext
from std.benchmark import (
    Bench,
    BenchConfig,
    Bencher,
    BenchId,
    ThroughputMeasure,
    Unit,
)


def run_pipeline[
    M: MapTracker,
    P: ParserTracker,
    TRACK_METRICS: Bool,
    once: Bool,
    no_print: Bool,
](filename: String) raises:
    comptime mode_str: String = "ANALYSIS" if TRACK_METRICS else "BENCHMARK"

    print("=" * 60)
    print("1BRC Unified Tool [Mode: ", mode_str, "] —", filename)
    print("=" * 60)

    # ── Phase 1: Mmap Setup ────────────────────────────────────────
    mapped = MappedFile(filename)
    ptr = mapped.ptr
    size = mapped.size

    comptime STREAMING_THRESHOLD = 0  # 8 GB
    use_streaming = size >= STREAMING_THRESHOLD

    if not use_streaming:
        mapped.advise(MADV_WILLNEED)
    # If streaming, we close mmap and use DoubleBufferedStream instead
    # to avoid page-fault thrashing on MacOS.

    # ── Phase 2: Parallel Pipeline ─────────────────────────────────
    t0_setup = perf_counter_ns()
    num_threads = num_logical_cores()
    chunk_size = size // num_threads

    chunk_starts = List[Int](capacity=num_threads + 1)
    chunk_starts.append(0)
    if not use_streaming:
        for i in range(1, num_threads):
            start_guess = i * chunk_size
            while start_guess > 0 and ptr[start_guess - 1] != 10:
                start_guess -= 1
            chunk_starts.append(start_guess)
    else:
        alignment_handle = FileHandle(filename)
        for i in range(1, num_threads):
            chunk_starts.append(
                find_first_newline(alignment_handle, i * chunk_size)
            )
        alignment_handle.close()
    chunk_starts.append(size)

    maps = List[PerfectStationMap[MAP_TRACKER=M]](capacity=num_threads)
    for _ in range(num_threads):
        maps.append(PerfectStationMap[MAP_TRACKER=M]())

    t1_setup = perf_counter_ns()
    print("Setup Time: ", Float64(t1_setup - t0_setup) / 1_000_000.0, " ms")

    # Determine if we should use the benchmark library or just run once
    # If we are in ANALYSIS mode, we don't need the benchmark library here
    # If we are in BENCHMARK mode, we use it to get high-precision engine stats

    @parameter
    def run_parallel[STREAMING: Bool]():
        @parameter
        def process_chunk(tid: Int):
            start = chunk_starts[tid]
            end = chunk_starts[tid + 1]
            maps_ptr = maps.unsafe_ptr()
            thread_metrics = P()

            comptime if STREAMING:
                # Use Buffered I/O for large files
                try:
                    handle = FileHandle(filename)
                    handle.set_nocache()
                    stream = DoubleBufferedStream(handle)
                    stream.process_range[P, M](
                        maps_ptr[unsafe_offset=tid],
                        start,
                        end,
                        thread_metrics,
                    )
                    stream.close()
                    handle.close()
                except e:
                    print("Streaming error in thread ", tid, ": ", e)
                    external_call["exit", NoneType](Int32(1))
            else:
                chunk_ptr = ptr + start
                chunk_len = end - start
                parse_chunk[P, M](
                    maps_ptr[unsafe_offset=tid],
                    chunk_ptr,
                    chunk_len,
                    thread_metrics,
                )

        def process_chunk_unified(tid: Int):
            process_chunk(tid)

        try:
            cpu_ctx = DeviceContext(api="cpu")
            cpu_ctx.enqueue_cpu_range(process_chunk_unified, count=num_threads)
            cpu_ctx.synchronize()
        except e:
            print("Parallel runtime error: ", e)
            external_call["exit", NoneType](Int32(1))

    comptime if not TRACK_METRICS and not once:
        # We use std.benchmark for the actual parsing phase
        config = BenchConfig(
            num_warmup_iters=1, max_iters=5, min_runtime_secs=0.5
        )
        b = Bench(config.copy())

        @parameter
        def bench_parse(mut bencher: Bencher):
            if use_streaming:
                bencher.iter[run_parallel[True]]()
            else:
                bencher.iter[run_parallel[False]]()

        # Use standard benchmark measures
        measures = List[ThroughputMeasure]()
        # 'datamovement' is a standard BenchMetric that expects 'bytes' (in G/s)
        measures.append(ThroughputMeasure("datamovement", size))

        b.bench_function[bench_parse](
            BenchId("Parallel Parse"), measures=measures
        )

        # Final Report
        print(b)
    else:
        # Just run once for analysis or if explicitly requested
        t0_parse = perf_counter_ns()
        if use_streaming:
            run_parallel[True]()
        else:
            run_parallel[False]()
        t1_parse = perf_counter_ns()
        comptime if TRACK_METRICS or once:
            print(
                "Parse Time: ",
                Float64(t1_parse - t0_parse) / 1_000_000.0,
                " ms",
            )

    # ── Phase 3: Merge & Print ─────────────────────────────────────
    t0_merge = perf_counter_ns()
    final_map = PerfectStationMap[MAP_TRACKER=M]()
    for i in range(num_threads):
        final_map.merge_from(maps[i])
    t1_merge = perf_counter_ns()

    comptime if not no_print:
        print("Merge Time: ", Float64(t1_merge - t0_merge) / 1_000_000.0, " ms")
        final_map.print_sorted()

    # ── Summary & Analysis Output ──────────────────────────────────
    comptime if TRACK_METRICS:
        run_analysis[M, P](filename, ptr, size, use_streaming, chunk_starts)

    mapped.close()


def main() raises:
    args = argv()
    filename = String("measurements_100m.txt")
    analyze_mode = False
    once_mode = False
    no_print = False

    for i in range(1, len(args)):
        arg = args[i]
        if arg == "--analyze" or arg == "-a":
            analyze_mode = True
        elif arg == "--once":
            once_mode = True
        elif arg == "--no-print":
            no_print = True
        else:
            filename = arg

    # Generic dispatch helper to bridge runtime flags to comptime specializations
    @parameter
    def dispatch[M: MapTracker, P: ParserTracker, TRACK: Bool]() raises:
        if once_mode:
            if no_print:
                run_pipeline[M, P, TRACK, True, True](filename)
            else:
                run_pipeline[M, P, TRACK, True, False](filename)
        else:
            if no_print:
                run_pipeline[M, P, TRACK, False, True](filename)
            else:
                run_pipeline[M, P, TRACK, False, False](filename)

    if analyze_mode:
        dispatch[MapMetrics, ParserMetrics, True]()

    else:
        dispatch[EmptyMapMetrics, EmptyParserMetrics, False]()
