from std.time import perf_counter_ns
from std.sys.info import num_logical_cores
from std.gpu.host import DeviceContext
from misc.metrics import MapTracker, ParserTracker
from engine.perfect_hashmap import PerfectStationMap
from engine.parser import parse_chunk
from IO.mmap import madvise_range, MADV_DONTNEED
from IO.streaming import FileHandle, DoubleBufferedStream


def run_analysis[
    M: MapTracker, P: ParserTracker
](
    filename: String,
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    size: Int,
    use_streaming: Bool,
    chunk_starts: List[Int],
) raises:
    """Perform a deep analysis pass over the data and print detailed metrics."""
    num_threads = num_logical_cores()

    # Re-run for detailed metric collection
    final_maps = List[PerfectStationMap[MAP_TRACKER=M]](capacity=num_threads)
    for _ in range(num_threads):
        final_maps.append(PerfectStationMap[MAP_TRACKER=M]())

    thread_parser_metrics = List[P](capacity=num_threads)
    for _ in range(num_threads):
        thread_parser_metrics.append(P())

    task_elapsed_ns = List[Int](capacity=num_threads)
    for _ in range(num_threads):
        task_elapsed_ns.append(0)

    t0 = perf_counter_ns()

    @parameter
    def collect_metrics(tid: Int):
        start = chunk_starts[tid]
        end = chunk_starts[tid + 1]
        maps_ptr = final_maps.unsafe_ptr()
        tpm_ptr = thread_parser_metrics.unsafe_ptr()
        elapsed_ptr = task_elapsed_ns.unsafe_ptr()
        task_t0 = perf_counter_ns()

        if use_streaming:
            try:
                handle = FileHandle(filename)
                handle.set_nocache()
                stream = DoubleBufferedStream(handle)
                stream.process_range[P, M](
                    maps_ptr[unsafe_offset=tid],
                    start,
                    end,
                    tpm_ptr[unsafe_offset=tid],
                )
                stream.close()
                handle.close()
            except e:
                print("Analysis Error in thread ", tid, ": ", e)
        else:
            chunk_ptr = ptr + start
            chunk_len = end - start
            parse_chunk[P, M](
                maps_ptr[unsafe_offset=tid],
                chunk_ptr,
                chunk_len,
                tpm_ptr[unsafe_offset=tid],
            )
        elapsed_ptr[unsafe_offset=tid] = perf_counter_ns() - task_t0

    def collect_metrics_unified(tid: Int):
        collect_metrics(tid)

    cpu_ctx = DeviceContext(api="cpu")
    cpu_ctx.enqueue_cpu_range(collect_metrics_unified, count=num_threads)
    cpu_ctx.synchronize()
    t1 = perf_counter_ns()
    parse_s = Float64(t1 - t0) / 1_000_000_000.0

    # Optional: cleanup after timing
    if use_streaming:
        for tid in range(num_threads):
            madvise_range(
                ptr + chunk_starts[tid],
                chunk_starts[tid + 1] - chunk_starts[tid],
                MADV_DONTNEED,
            )

    # Aggregate Map Metrics & Parser Metrics
    total_parser_metrics = P()
    final_merged_map = PerfectStationMap[MAP_TRACKER=M]()

    for i in range(num_threads):
        ref m = final_maps[i]
        final_merged_map.merge_from(m)
        ref p = thread_parser_metrics[i]
        total_parser_metrics.merge_from(p)

    print(
        "\n── Deep Analysis Results"
        " ──────────────────────────────────────────────"
    )
    total_parser_metrics.print_summary(size, parse_s)
    final_merged_map.metrics.print_summary()

    fastest_ns = task_elapsed_ns[0]
    slowest_ns = task_elapsed_ns[0]
    print(
        "\n── Task Timing"
        " ────────────────────────────────────────────────────────"
    )
    for tid in range(num_threads):
        elapsed_ns = task_elapsed_ns[tid]
        fastest_ns = min(fastest_ns, elapsed_ns)
        slowest_ns = max(slowest_ns, elapsed_ns)
        print(
            "  Task ",
            tid,
            ": ",
            Float64(elapsed_ns) / 1_000_000.0,
            " ms; ",
            chunk_starts[tid + 1] - chunk_starts[tid],
            " bytes",
        )
    skew_pct = (
        Float64(slowest_ns - fastest_ns) / max(Float64(slowest_ns), 1.0) * 100.0
    )
    print("  Fastest: ", Float64(fastest_ns) / 1_000_000.0, " ms")
    print("  Slowest: ", Float64(slowest_ns) / 1_000_000.0, " ms")
    print("  Closing skew: ", skew_pct, "%")

    print("\n  I/O Strategy: ", "Streaming" if use_streaming else "Preload")
    print("  Mapped Size:  ", size, " bytes")
