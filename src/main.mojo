from std.sys import argv
from std.sys.info import num_logical_cores
from std.time import perf_counter_ns
from engine.perfect_hashmap import PerfectStationMap
from misc.metrics import EmptyMapMetrics, EmptyParserMetrics
from engine.parser import parse_chunk
from IO.mmap import (
    MappedFile,
    MADV_SEQUENTIAL,
    MADV_WILLNEED,
    MADV_DONTNEED,
    madvise_range,
)
from std.gpu.host import DeviceContext


def main() raises:
    filename = "measurements_600m.txt"
    if len(argv()) > 1:
        filename = argv()[1]

    print("Reading", filename, "...")

    mapped = MappedFile(filename)
    ptr = mapped.ptr
    size = mapped.size

    # < 8 GB  → MADV_WILLNEED: bulk-preload into RAM (300m fits, runs at CPU speed).
    # ≥ 8 GB  → MADV_SEQUENTIAL: stream on demand; release pages after each chunk.
    comptime STREAMING_THRESHOLD = 8 * 1024 * 1024 * 1024  # 8 GB
    use_streaming = size >= STREAMING_THRESHOLD
    if use_streaming:
        mapped.advise(MADV_SEQUENTIAL)
    else:
        mapped.advise(MADV_WILLNEED)

    t0_setup = perf_counter_ns()
    num_threads = num_logical_cores()
    chunk_size = size // num_threads

    chunk_starts = List[Int](capacity=num_threads + 1)
    chunk_starts.append(0)
    for i in range(1, num_threads):
        start_guess = i * chunk_size
        while start_guess > 0 and ptr[start_guess - 1] != 10:
            start_guess -= 1
        chunk_starts.append(start_guess)
    chunk_starts.append(size)

    maps = List[PerfectStationMap[MAP_TRACKER=EmptyMapMetrics]](
        capacity=num_threads
    )
    for _ in range(num_threads):
        maps.append(PerfectStationMap[MAP_TRACKER=EmptyMapMetrics]())

    t1_setup = perf_counter_ns()
    print("Setup Time: ", Float64(t1_setup - t0_setup) / 1_000_000.0, " ms")

    print("Parallel Parse ...")
    t0_parse = perf_counter_ns()

    @parameter
    def run_parallel[STREAMING: Bool]() raises:
        @parameter
        def process_chunk(tid: Int):
            start = chunk_starts[tid]
            end = chunk_starts[tid + 1]
            chunk_ptr = ptr + start
            chunk_len = end - start
            maps_ptr = maps.unsafe_ptr()
            metrics = EmptyParserMetrics()
            parse_chunk[EmptyParserMetrics, EmptyMapMetrics](
                maps_ptr[unsafe_offset=tid],
                chunk_ptr,
                chunk_len,
                metrics,
            )
            comptime if STREAMING:
                madvise_range(chunk_ptr, chunk_len, MADV_DONTNEED)

        def process_chunk_unified(tid: Int):
            process_chunk(tid)

        cpu_ctx = DeviceContext(api="cpu")
        cpu_ctx.enqueue_cpu_range(process_chunk_unified, count=num_threads)
        cpu_ctx.synchronize()

    if use_streaming:
        run_parallel[True]()
    else:
        run_parallel[False]()
    t1_parse = perf_counter_ns()
    print("Parse Time: ", Float64(t1_parse - t0_parse) / 1_000_000.0, " ms")

    # Merge all thread-local hashmaps into the first one
    print("Merge Maps ...")
    t0_merge = perf_counter_ns()
    final_map = PerfectStationMap[MAP_TRACKER=EmptyMapMetrics]()
    for i in range(num_threads):
        final_map.merge_from(maps[i])
    t1_merge = perf_counter_ns()
    print("Merge Time: ", Float64(t1_merge - t0_merge) / 1_000_000.0, " ms")

    final_map.print_sorted()
    mapped.close()
