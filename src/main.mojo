from std.sys import argv
from std.sys.info import num_logical_cores
from perfect_hashmap import PerfectStationMap
from parser import parse_chunk, ParserMetrics
from mmap import MappedFile, MADV_SEQUENTIAL, MADV_DONTNEED, madvise_range, MADV_WILLNEED
from std.algorithm import parallelize


from profiler import Profiler


def main() raises:
    var filename = "measurements_600m.txt"
    if len(argv()) > 1:
        filename = argv()[1]

    var prof = Profiler()
    print("Reading", filename, "...")

    prof.tic("I/O Setup (mmap)")
    var mapped = MappedFile(filename)
    var ptr = mapped.ptr
    var size = mapped.size
    comptime STREAMING_THRESHOLD = 8 * 1024 * 1024 * 1024  # 8 GB
    var use_streaming = size >= STREAMING_THRESHOLD
    if use_streaming:
        mapped.advise(MADV_SEQUENTIAL)
    else:
        mapped.advise(MADV_WILLNEED)
    var num_threads = num_logical_cores()
    var chunk_size = size // num_threads

    # Find safe chunk boundaries (must avoid splitting lines)
    prof.tic("Chunk Boundary Calculation")
    var chunk_starts = List[Int](capacity=num_threads + 1)
    chunk_starts.append(0)

    for i in range(1, num_threads):
        var start_guess = i * chunk_size
        # Retreat to the previous newline
        while start_guess > 0 and ptr[start_guess - 1] != 10:
            start_guess -= 1
        chunk_starts.append(start_guess)

    chunk_starts.append(size)
    prof.toc("Chunk Boundary Calculation")

    # Initialize thread-local hashmaps
    prof.tic("Map Initialization")
    var maps = List[PerfectStationMap[TRACK_METRICS=False]](
        capacity=num_threads
    )
    for _ in range(num_threads):
        maps.append(PerfectStationMap[TRACK_METRICS=False]())
    prof.toc("Map Initialization")

    prof.tic("Parallel Parse")

    @parameter
    fn process_chunk[STREAMING: Bool](tid: Int):
        var start = chunk_starts[tid]
        var end = chunk_starts[tid + 1]
        var chunk_ptr = ptr + start
        var chunk_len = end - start

        var maps_ptr = maps.unsafe_ptr()
        var metrics = ParserMetrics()
        parse_chunk(maps_ptr[tid], chunk_ptr, chunk_len, metrics)
        comptime if STREAMING:
            madvise_range(chunk_ptr, chunk_len, MADV_DONTNEED)

    if use_streaming:
        parallelize[process_chunk[True]](num_threads)
    else:
        parallelize[process_chunk[False]](num_threads)
    prof.toc("Parallel Parse")

    # Merge all thread-local hashmaps into the first one
    prof.tic("Merge Maps")
    var final_map = PerfectStationMap[TRACK_METRICS=False]()
    for i in range(num_threads):
        final_map.merge_from(maps[i])
    prof.toc("Merge Maps")

    prof.report()

    final_map.print_sorted()

    mapped.close()
