from std.random import seed, random_si64
from std.gpu.host import DeviceContext
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


def get_station_hash_original(s: String) -> UInt64:
    b = s.as_bytes()
    length = len(b)
    if length < 2:
        return 0
    val = UInt64(length)
    val |= UInt64(b[0]) << 8
    val |= UInt64(b[length >> 1]) << 16
    val |= UInt64(b[length - 1]) << 24
    val |= UInt64(b[1]) << 32
    val |= UInt64(b[length - 2]) << 40
    return val


def get_station_hash_xor5(s: String) -> UInt64:
    b = s.as_bytes()
    length = len(b)
    if length < 2:
        return 0
    b0 = UInt64(b[0])
    b1 = UInt64(b[1])
    bm = UInt64(b[length >> 1])
    bL = UInt64(b[length - 1])
    bL1 = UInt64(b[length - 2])
    val = UInt64(length)
    val ^= b0 | (b0 << 32)
    val ^= (b1 << 8) | (b1 << 40)
    val ^= bm << 16
    val ^= bL << 24
    val ^= bL1 << 48
    val ^= (b0 ^ bL) << 56
    return val


def get_station_hash_xor4(s: String) -> UInt64:
    b = s.as_bytes()
    length = len(b)
    if length < 2:
        return 0
    b0 = UInt64(b[0])
    b1 = UInt64(b[1])
    bm = UInt64(b[length >> 1])
    bL = UInt64(b[length - 1])
    val = UInt64(length)
    val ^= b0 | (b0 << 32)
    val ^= (b1 << 8) | (b1 << 40)
    val ^= bm << 16
    val ^= bL << 24
    val ^= (b0 ^ bL) << 56
    return val


def get_station_hash_xor3(s: String) -> UInt64:
    b = s.as_bytes()
    length = len(b)
    if length < 2:
        return 0
    b0 = UInt64(b[0])
    bm = UInt64(b[length >> 1])
    bL = UInt64(b[length - 1])
    val = UInt64(length)
    val ^= b0 | (b0 << 24) | (b0 << 48)
    val ^= (bm << 8) | (bm << 32)
    val ^= (bL << 16) | (bL << 40)
    val ^= (b0 ^ bL ^ bm) << 56
    return val


def get_station_hash_head3_tailm3(s: String) -> UInt64:
    """4 loads: b[0], b[1], b[2] via one uint32 load + b[-3] via one byte load.
    """
    b = s.as_bytes()
    length = len(b)
    if length < 3:
        return 0
    # Single 4-byte load covers b[0], b[1], b[2] (and b[3] which we mask out)
    head = UInt64(b[0]) | (UInt64(b[1]) << 8) | (UInt64(b[2]) << 16)
    val = UInt64(length)
    val |= (
        head & 0xFFFFFF
    ) << 8  # b[0] at bits 8-15, b[1] at 16-23, b[2] at 24-31
    val |= UInt64(b[length - 3]) << 32
    return val


def get_station_hash_minimal(s: String) -> UInt64:
    b = s.as_bytes()
    length = len(b)
    if length < 3:
        return 0
    head: UInt64 = 0
    head |= UInt64(b[0])
    head |= UInt64(b[1]) << 8
    head |= UInt64(b[2]) << 16
    if length >= 4:
        head |= UInt64(b[3]) << 24
    else:
        head |= UInt64(ord(";")) << 24

    tail_byte = UInt64(b[length - 3])
    return head | (tail_byte << 32)


def get_station_hash(s: String, strategy: Int) -> UInt64:
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
def check_multiplier_opt(
    m: UInt64,
    hashes: UnsafePointer[UInt64, MutUntrackedOrigin],
    num_hashes: Int,
    shift: Int,
    mask: Int,
    seen: UnsafePointer[UInt32, MutUntrackedOrigin],
    attempt_id: UInt32,
) -> Bool:
    for i in range(num_hashes):
        h = hashes[i]
        idx = Int((h * m) >> UInt64(shift)) & mask
        if seen[idx] == attempt_id:
            return False
        seen[idx] = attempt_id
    return True


def get_bit_length(n: Int) -> Int:
    if n == 0:
        return 0
    return 64 - Int(count_leading_zeros(UInt64(n)))


def main() raises:
    input_path = "docs/stations413.txt"
    output_path = "src/engine/stations_data.mojo"
    max_attempts = 1_000_000_000
    target_cap = 16384
    strategy = 0  # 0=original, 1=xor5, 2=xor4, 3=xor3

    args = argv()
    if len(args) > 1:
        max_attempts = Int(args[1])
    if len(args) > 2:
        target_cap = Int(args[2])
    if len(args) > 3:
        strategy = Int(args[3])

    print("Loading stations from", input_path, "...")
    f = open(input_path, "r")
    # lines contains slices borrowed from content, so make their shared block
    # lifetime explicit instead of relying on function-scoped inference.
    var content = f.read()
    f.close()

    var lines = content.split("\n")
    stations = List[String]()
    hashes_list = List[UInt64]()

    strategy_names = List[String]()
    strategy_names.append("original")
    strategy_names.append("xor5")
    strategy_names.append("xor4")
    strategy_names.append("xor3")
    strategy_names.append("head3_tailm3")
    strategy_names.append("minimal")
    print("Strategy:", strategy_names[strategy])

    for i in range(len(lines)):
        var line = String(lines[i].strip())
        if line.byte_length() > 0:
            stations.append(line)
            hashes_list.append(get_station_hash(line, strategy))
    _ = lines
    _ = content

    # Check key uniqueness
    unique_count = 0
    for i in range(len(hashes_list)):
        is_unique = True
        for j in range(i):
            if hashes_list[i] == hashes_list[j]:
                is_unique = False
                print(
                    "  KEY COLLISION:",
                    stations[i],
                    "collides with",
                    stations[j],
                )
                break
        if is_unique:
            unique_count += 1
    if unique_count != len(hashes_list):
        print(
            "FATAL: Strategy has",
            len(hashes_list) - unique_count,
            "key collisions. Cannot proceed.",
        )
        return

    print("Loaded", len(stations), "stations. All keys unique.")

    num_hashes = len(hashes_list)
    hashes_ptr = alloc[UInt64](num_hashes)
    for i in range(num_hashes):
        hashes_ptr[i] = hashes_list[i]

    capacities = List[Int]()
    capacities.append(target_cap)

    num_workers = num_logical_cores()
    max_cap = 16384
    seen_buffers = alloc[UInt32](num_workers * max_cap)
    for i in range(num_workers * max_cap):
        seen_buffers[i] = 0

    found_ptr = alloc[Int](1)
    mult_ptr = alloc[UInt64](1)

    for i in range(len(capacities)):
        cap = capacities[i]
        shift = 64 - get_bit_length(cap) + 1
        if (cap & (cap - 1)) == 0:
            shift = 64 - get_bit_length(cap - 1)

        print("\n── Trying capacity", cap, "(shift", shift, ") ──")
        print(
            "  Searching with",
            max_attempts,
            "attempts across",
            num_workers,
            "workers...",
        )
        found_ptr[0] = 0
        mult_ptr[0] = 0

        t0 = perf_counter_ns()
        attempts_per_worker = max_attempts // num_workers
        mask = cap - 1

        @parameter
        def search(tid: Int):
            seen = seen_buffers + (tid * max_cap)
            seed()

            for attempt in range(attempts_per_worker):
                if found_ptr[0] > 0:
                    return
                attempt_id = UInt32(attempt + 1)
                m = UInt64(random_si64(0, 0x7FFFFFFFFFFFFFFF)) | 1
                if check_multiplier_opt(
                    m, hashes_ptr, num_hashes, shift, mask, seen, attempt_id
                ):
                    if found_ptr[0] == 0:
                        mult_ptr[0] = m
                        found_ptr[0] = 1
                    return

        def search_unified(tid: Int):
            search(tid)

        cpu_ctx = DeviceContext(api="cpu")
        cpu_ctx.enqueue_cpu_range(search_unified, count=num_workers)
        cpu_ctx.synchronize()

        t1 = perf_counter_ns()
        duration = Float64(t1 - t0) / 1_000_000_000.0
        attempts_sec = Float64(max_attempts) / duration

        if found_ptr[0] > 0:
            m = mult_ptr[0]
            print("  FOUND multiplier after", duration, "seconds:", m)
            print("  Throughput:", attempts_sec / 1_000_000.0, "M attempts/sec")

            print("Writing to", output_path, "...")
            out_f = open(output_path, "w")
            out_f.write(
                "# Automatically generated by scripts/generate_stations.mojo\n"
            )
            out_f.write(
                "# strategy="
                + strategy_names[strategy]
                + ", capacity="
                + String(cap)
                + ", shift="
                + String(shift)
                + "\n"
            )
            out_f.write("comptime STATION_NAMES = (\n")
            for j in range(len(stations)):
                name = stations[j]
                out_f.write('    "' + name + '"')
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

            out_f.write(
                "comptime PERFECT_MULTIPLIER: UInt64 = " + String(m) + "\n"
            )
            out_f.write(
                "comptime PERFECT_CAPACITY: Int = " + String(cap) + "\n"
            )
            out_f.write("comptime PERFECT_SHIFT: Int = " + String(shift) + "\n")
            out_f.close()
            return

        print(
            "  No multiplier found for capacity",
            cap,
            "after",
            duration,
            "seconds.",
        )
        print("  Throughput:", attempts_sec / 1_000_000.0, "M attempts/sec")

    print("\nFAILED: Could not find a perfect multiplier for any capacity.")
