from std.random import seed, random_si64
from std.algorithm import parallelize
from std.time import perf_counter_ns
from std.sys.info import num_logical_cores
from std.io.file import open
from std.sys import argv
from std.bit import count_leading_zeros
from std.memory import UnsafePointer, alloc

# ── Key construction strategies ──────────────────────────────────────────────
# Strategy 0: original (5 loads, OR lanes)
# Strategy 1: xor5 (5 loads, XOR-folded)
# Strategy 2: xor4 (4 loads, drop ptr[len-2])
# Strategy 3: xor3 (3 loads, only b0, mid, last)

fn get_station_hash_original(s: String) -> UInt64:
    var b = s.as_bytes()
    var length = len(b)
    if length < 2:
        return 0
    var val = UInt64(length)
    val |= UInt64(b[0]) << 8
    val |= UInt64(b[length >> 1]) << 16
    val |= UInt64(b[length - 1]) << 24
    val |= UInt64(b[1]) << 32
    val |= UInt64(b[length - 2]) << 40
    return val

fn get_station_hash_xor5(s: String) -> UInt64:
    var b = s.as_bytes()
    var length = len(b)
    if length < 2:
        return 0
    var b0 = UInt64(b[0])
    var b1 = UInt64(b[1])
    var bm = UInt64(b[length >> 1])
    var bL = UInt64(b[length - 1])
    var bL1 = UInt64(b[length - 2])
    var val = UInt64(length)
    val ^= b0 | (b0 << 32)
    val ^= (b1 << 8) | (b1 << 40)
    val ^= bm << 16
    val ^= bL << 24
    val ^= bL1 << 48
    val ^= (b0 ^ bL) << 56
    return val

fn get_station_hash_xor4(s: String) -> UInt64:
    var b = s.as_bytes()
    var length = len(b)
    if length < 2:
        return 0
    var b0 = UInt64(b[0])
    var b1 = UInt64(b[1])
    var bm = UInt64(b[length >> 1])
    var bL = UInt64(b[length - 1])
    var val = UInt64(length)
    val ^= b0 | (b0 << 32)
    val ^= (b1 << 8) | (b1 << 40)
    val ^= bm << 16
    val ^= bL << 24
    val ^= (b0 ^ bL) << 56
    return val

fn get_station_hash_xor3(s: String) -> UInt64:
    var b = s.as_bytes()
    var length = len(b)
    if length < 2:
        return 0
    var b0 = UInt64(b[0])
    var bm = UInt64(b[length >> 1])
    var bL = UInt64(b[length - 1])
    var val = UInt64(length)
    val ^= b0 | (b0 << 24) | (b0 << 48)
    val ^= (bm << 8) | (bm << 32)
    val ^= (bL << 16) | (bL << 40)
    val ^= (b0 ^ bL ^ bm) << 56
    return val

fn get_station_hash_head3_tailm3(s: String) -> UInt64:
    """4 loads: b[0], b[1], b[2] via one uint32 load + b[-3] via one byte load."""
    var b = s.as_bytes()
    var length = len(b)
    if length < 3:
        return 0
    # Single 4-byte load covers b[0], b[1], b[2] (and b[3] which we mask out)
    var head = UInt64(b[0]) | (UInt64(b[1]) << 8) | (UInt64(b[2]) << 16)
    var val = UInt64(length)
    val |= (head & 0xFFFFFF) << 8    # b[0] at bits 8-15, b[1] at 16-23, b[2] at 24-31
    val |= UInt64(b[length - 3]) << 32
    return val

fn get_station_hash_minimal(s: String) -> UInt64:
    var b = s.as_bytes()
    var length = len(b)
    if length < 3:
        return 0
    var head: UInt64 = 0
    head |= UInt64(b[0])
    head |= UInt64(b[1]) << 8
    head |= UInt64(b[2]) << 16
    if length >= 4:
        head |= UInt64(b[3]) << 24
    else:
        head |= UInt64(ord(";")) << 24

    var tail_byte = UInt64(b[length - 3])
    return head | (tail_byte << 32)

fn get_station_hash(s: String, strategy: Int) -> UInt64:
    if strategy == 1:
        return get_station_hash_xor5(s)
    elif strategy == 2:
        return get_station_hash_xor4(s)
    elif strategy == 3:
        return get_station_hash_xor3(s)
    elif strategy == 4:
        return get_station_hash_head3_tailm3(s)
    elif strategy == 5:
        return get_station_hash_minimal(s)
    return get_station_hash_original(s)

@always_inline
fn check_multiplier_opt(
    m: UInt64, 
    hashes: UnsafePointer[UInt64, MutExternalOrigin], 
    num_hashes: Int,
    shift: Int, 
    mask: Int,
    seen: UnsafePointer[UInt32, MutExternalOrigin],
    attempt_id: UInt32
) -> Bool:
    for i in range(num_hashes):
        var h = hashes[i]
        var idx = Int((h * m) >> UInt64(shift)) & mask
        if seen[idx] == attempt_id:
            return False
        seen[idx] = attempt_id
    return True

fn get_bit_length(n: Int) -> Int:
    if n == 0: return 0
    return 64 - Int(count_leading_zeros(UInt64(n)))

def main() raises:
    var input_path = "docs/stations413.txt"
    var output_path = "src/engine/stations_data.mojo"
    var max_attempts = 1_000_000_000
    var target_cap = 16384
    var strategy = 0  # 0=original, 1=xor5, 2=xor4, 3=xor3

    var args = argv()
    if len(args) > 1:
        max_attempts = Int(args[1])
    if len(args) > 2:
        target_cap = Int(args[2])
    if len(args) > 3:
        strategy = Int(args[3])
    
    print("Loading stations from", input_path, "...")
    var f = open(input_path, "r")
    var content = f.read()
    f.close()
    
    var lines = content.split("\n")
    var stations = List[String]()
    var hashes_list = List[UInt64]()
    
    var strategy_names = List[String]()
    strategy_names.append("original")
    strategy_names.append("xor5")
    strategy_names.append("xor4")
    strategy_names.append("xor3")
    strategy_names.append("head3_tailm3")
    strategy_names.append("minimal")
    print("Strategy:", strategy_names[strategy])

    for i in range(len(lines)):
        var line_slice = lines[i].strip()
        if len(line_slice) > 0:
            var line = String(line_slice)
            stations.append(line)
            hashes_list.append(get_station_hash(line, strategy))

    # Check key uniqueness
    var unique_count = 0
    for i in range(len(hashes_list)):
        var is_unique = True
        for j in range(i):
            if hashes_list[i] == hashes_list[j]:
                is_unique = False
                print("  KEY COLLISION:", stations[i], "collides with", stations[j])
                break
        if is_unique:
            unique_count += 1
    if unique_count != len(hashes_list):
        print("FATAL: Strategy has", len(hashes_list) - unique_count, "key collisions. Cannot proceed.")
        return

    print("Loaded", len(stations), "stations. All keys unique.")
    
    var num_hashes = len(hashes_list)
    var hashes_ptr = alloc[UInt64](num_hashes)
    for i in range(num_hashes):
        hashes_ptr[i] = hashes_list[i]
        
    var capacities = List[Int]()
    capacities.append(target_cap)
    
    var num_workers = num_logical_cores()
    var max_cap = 16384
    var seen_buffers = alloc[UInt32](num_workers * max_cap)
    for i in range(num_workers * max_cap):
        seen_buffers[i] = 0
    
    var found_ptr = alloc[Int](1)
    var mult_ptr = alloc[UInt64](1)
    
    for i in range(len(capacities)):
        var cap = capacities[i]
        var shift = 64 - get_bit_length(cap) + 1
        if (cap & (cap - 1)) == 0:
            shift = 64 - get_bit_length(cap - 1)
        
        print("\n── Trying capacity", cap, "(shift", shift, ") ──")
        print("  Searching with", max_attempts, "attempts across", num_workers, "workers...")
        found_ptr[0] = 0
        mult_ptr[0] = 0
        
        var t0 = perf_counter_ns()
        var attempts_per_worker = max_attempts // num_workers
        var mask = cap - 1
        
        @parameter
        fn search(tid: Int):
            var seen = seen_buffers + (tid * max_cap)
            seed() 
            
            for attempt in range(attempts_per_worker):
                if found_ptr[0] > 0:
                    return
                var attempt_id = UInt32(attempt + 1)
                var m = UInt64(random_si64(0, 0x7FFFFFFFFFFFFFFF)) | 1
                if check_multiplier_opt(m, hashes_ptr, num_hashes, shift, mask, seen, attempt_id):
                    if found_ptr[0] == 0:
                        mult_ptr[0] = m
                        found_ptr[0] = 1
                    return
        
        parallelize[search](num_workers)
        
        var t1 = perf_counter_ns()
        var duration = Float64(t1 - t0) / 1_000_000_000.0
        var attempts_sec = Float64(max_attempts) / duration
        
        if found_ptr[0] > 0:
            var m = mult_ptr[0]
            print("  FOUND multiplier after", duration, "seconds:", m)
            print("  Throughput:", attempts_sec / 1_000_000.0, "M attempts/sec")
            
            print("Writing to", output_path, "...")
            var out_f = open(output_path, "w")
            out_f.write("# Automatically generated by scripts/generate_stations.mojo\n")
            out_f.write("# strategy=" + strategy_names[strategy] + ", capacity=" + String(cap) + ", shift=" + String(shift) + "\n")
            out_f.write("comptime STATION_NAMES = (\n")
            for j in range(len(stations)):
                var name = stations[j]
                out_f.write("    \"" + name + "\"")
                if j < len(stations) - 1:
                    out_f.write(",")
                out_f.write("\n")
            out_f.write(")\n\n")
            
            out_f.write("comptime STATION_HASHES = (\n")
            for j in range(len(hashes_list)):
                out_f.write("    " + String(hashes_list[j]))
                if j < len(hashes_list) - 1:
                    out_f.write(",")
                out_f.write("\n")
            out_f.write(")\n\n")
            
            out_f.write("comptime PERFECT_MULTIPLIER: UInt64 = " + String(m) + "\n")
            out_f.write("comptime PERFECT_CAPACITY: Int = " + String(cap) + "\n")
            out_f.write("comptime PERFECT_SHIFT: Int = " + String(shift) + "\n")
            out_f.close()
            return
            
        print("  No multiplier found for capacity", cap, "after", duration, "seconds.")
        print("  Throughput:", attempts_sec / 1_000_000.0, "M attempts/sec")

    print("\nFAILED: Could not find a perfect multiplier for any capacity.")
