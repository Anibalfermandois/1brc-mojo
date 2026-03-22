from std.time import perf_counter_ns
from std.sys.info import num_logical_cores
from std.algorithm import parallelize
from misc.metrics import MapTracker, ParserTracker
from engine.perfect_hashmap import PerfectStationMap
from engine.parser import parse_chunk
from IO.mmap import madvise_range, MADV_DONTNEED
from IO.streaming import FileHandle, DoubleBufferedStream

def run_analysis[M: MapTracker, P: ParserTracker](
    filename: String,
    ptr: UnsafePointer[UInt8, MutExternalOrigin],
    size: Int,
    use_streaming: Bool,
    chunk_starts: List[Int]
) raises:
    """Perform a deep analysis pass over the data and print detailed metrics."""
    var num_threads = num_logical_cores()
    
    # Re-run for detailed metric collection
    var final_maps = List[PerfectStationMap[MAP_TRACKER=M]](capacity=num_threads)
    for _ in range(num_threads):
        final_maps.append(PerfectStationMap[MAP_TRACKER=M]())
    
    var thread_parser_metrics = List[P](capacity=num_threads)
    for _ in range(num_threads):
        thread_parser_metrics.append(P())

    var t0 = perf_counter_ns()
    
    @parameter
    fn collect_metrics(tid: Int):
        var start      = chunk_starts[tid]
        var end        = chunk_starts[tid + 1]
        var maps_ptr   = final_maps.unsafe_ptr()
        var tpm_ptr    = thread_parser_metrics.unsafe_ptr()
        
        if use_streaming:
            try:
                var handle = FileHandle(filename)
                handle.set_nocache()
                var stream = DoubleBufferedStream(handle)
                stream.process_range[P,M](maps_ptr[tid], start, end, tpm_ptr[tid])
                stream.close()
                handle.close()
            except e:
                print("Analysis Error in thread ", tid, ": ", e)
        else:
            var chunk_ptr  = ptr + start
            var chunk_len  = end - start
            parse_chunk[P, M](maps_ptr[tid], chunk_ptr, chunk_len, tpm_ptr[tid])
    
    parallelize[collect_metrics](num_threads)
    var t1 = perf_counter_ns()
    var parse_s = Float64(t1 - t0) / 1_000_000_000.0

    # Optional: cleanup after timing
    if use_streaming:
        for tid in range(num_threads):
            madvise_range(ptr + chunk_starts[tid], chunk_starts[tid+1] - chunk_starts[tid], MADV_DONTNEED)

    # Aggregate Map Metrics & Parser Metrics
    var total_parser_metrics = P()
    var final_merged_map = PerfectStationMap[MAP_TRACKER=M]()
    
    for i in range(num_threads):
        ref m = final_maps[i]
        final_merged_map.merge_from(m)
        ref p = thread_parser_metrics[i]
        total_parser_metrics.merge_from(p)

    print("\n── Deep Analysis Results ──────────────────────────────────────────────")
    total_parser_metrics.print_summary(size, parse_s)
    final_merged_map.metrics.print_summary()
    
    print("\n  I/O Strategy: ", "Streaming" if use_streaming else "Preload")
    print("  Mapped Size:  ", size, " bytes")
