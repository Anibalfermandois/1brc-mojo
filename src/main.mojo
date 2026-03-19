from std.sys import argv
from std.sys.info import num_logical_cores
from std.time import perf_counter_ns
from perfect_hashmap import PerfectStationMap
from metrics import EmptyMapMetrics, EmptyParserMetrics
from parser import parse_chunk
from mmap import MappedFile, MADV_SEQUENTIAL, MADV_WILLNEED, MADV_DONTNEED, madvise_range
from std.algorithm import parallelize

def main() raises:
    var filename = "measurements_600m.txt"
    if len(argv()) > 1:
        filename = argv()[1]

    print("Reading", filename, "...")

    var mapped = MappedFile(filename)
    var ptr = mapped.ptr
    var size = mapped.size

    # < 8 GB  → MADV_WILLNEED: bulk-preload into RAM (300m fits, runs at CPU speed).
    # ≥ 8 GB  → MADV_SEQUENTIAL: stream on demand; release pages after each chunk.
    comptime STREAMING_THRESHOLD = 8 * 1024 * 1024 * 1024  # 8 GB
    var use_streaming = size >= STREAMING_THRESHOLD
    if use_streaming:
        mapped.advise(MADV_SEQUENTIAL)
    else:
        mapped.advise(MADV_WILLNEED)

    var t0_setup = perf_counter_ns()
    var num_threads = num_logical_cores()
    var chunk_size = size // num_threads

    var chunk_starts = List[Int](capacity=num_threads + 1)
    chunk_starts.append(0)
    for i in range(1, num_threads):
        var start_guess = i * chunk_size
        while start_guess > 0 and ptr[start_guess - 1] != 10:
            start_guess -= 1
        chunk_starts.append(start_guess)
    chunk_starts.append(size)

    var maps = List[PerfectStationMap[MAP_TRACKER=EmptyMapMetrics]](capacity=num_threads)
    for _ in range(num_threads):
        maps.append(PerfectStationMap[MAP_TRACKER=EmptyMapMetrics]())
    
    var t1_setup = perf_counter_ns()
    print("Setup Time: ", Float64(t1_setup - t0_setup) / 1_000_000.0, " ms")

    print("Parallel Parse ...")
    var t0_parse = perf_counter_ns()
    @parameter
    def process_chunk[STREAMING: Bool](tid: Int):
        var start     = chunk_starts[tid]
        var end       = chunk_starts[tid + 1]
        var chunk_ptr = ptr + start
        var chunk_len = end - start
        var maps_ptr  = maps.unsafe_ptr()
        var metrics   = EmptyParserMetrics()
        parse_chunk[EmptyParserMetrics, EmptyMapMetrics](maps_ptr[tid], chunk_ptr, chunk_len, metrics)
        comptime if STREAMING:
            madvise_range(chunk_ptr, chunk_len, MADV_DONTNEED)

    if use_streaming:
        parallelize[process_chunk[True]](num_threads)
    else:
        parallelize[process_chunk[False]](num_threads)
    var t1_parse = perf_counter_ns()
    print("Parse Time: ", Float64(t1_parse - t0_parse) / 1_000_000.0, " ms")

    # Merge all thread-local hashmaps into the first one
    print("Merge Maps ...")
    var t0_merge = perf_counter_ns()
    var final_map = PerfectStationMap[MAP_TRACKER=EmptyMapMetrics]()
    for i in range(num_threads):
        final_map.merge_from(maps[i])
    var t1_merge = perf_counter_ns()
    print("Merge Time: ", Float64(t1_merge - t0_merge) / 1_000_000.0, " ms")

    final_map.print_sorted()
    mapped.close()
