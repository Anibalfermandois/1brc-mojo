import sys
import random

def load_stations(filename):
    with open(filename, 'r') as f:
        return [line.strip() for line in f if line.strip()]

def string_to_int(s):
    b = s.encode('utf-8')
    val = len(b)
    for i in range(min(4, len(b))): val |= (b[i] << (8 * (i + 1)))
    for i in range(min(3, len(b))): val |= (b[-(i+1)] << (8 * (i + 5)))
    return val

def find_perfect_hash(stations):
    int_keys = [string_to_int(s) for s in stations]
    table_size = 8192
    shift = 64 - 13
    
    attempts = 0
    while attempts < 2_000_000:
        attempts += 1
        m = random.getrandbits(64) | 1 # Must be odd
        
        indices = set()
        collision = False
        for k in int_keys:
            idx = ((k * m) & 0xFFFFFFFFFFFFFFFF) >> shift
            if idx in indices:
                collision = True
                break
            indices.add(idx)
            
        if not collision:
            return m, shift, table_size
    return None

if __name__ == '__main__':
    stations = load_stations('stations413.txt')
    m, shift, size = find_perfect_hash(stations)
    
    mapped = {}
    for s in stations:
        k = string_to_int(s)
        idx = ((k * m) & 0xFFFFFFFFFFFFFFFF) >> shift
        mapped[idx] = s

    mojo_code = f"""from std.memory import UnsafePointer

@fieldwise_init
struct StationStats(Copyable, Movable):
    var min: Int
    var max: Int
    var sum: Int
    var count: Int

    fn __init__(out self, initial_temp: Int):
        self.min = initial_temp
        self.max = initial_temp
        self.sum = initial_temp
        self.count = 1

    fn __copyinit__(out self, copy: Self):
        self.min = copy.min
        self.max = copy.max
        self.sum = copy.sum
        self.count = copy.count

    fn __moveinit__(out self, deinit take: Self):
        self.min = take.min
        self.max = take.max
        self.sum = take.sum
        self.count = take.count

    @always_inline
    fn update(mut self, temp: Int):
        if temp < self.min:
            self.min = temp
        if temp > self.max:
            self.max = temp
        self.sum += temp
        self.count += 1

    fn mean(self) -> Float64:
        if self.count == 0:
            return 0.0
        return Float64(self.sum) / (Float64(self.count) * 10.0)

# Optional metrics for analyze.mojo tracking
struct MapMetrics(Copyable, Movable):
    var total_lookups: Int
    var total_inserts: Int
    var total_updates: Int
    var total_probes: Int
    var max_probe_run: Int

    fn __init__(out self):
        self.total_lookups = 0
        self.total_inserts = 0
        self.total_updates = 0
        self.total_probes = 0
        self.max_probe_run = 0

    fn __copyinit__(out self, copy: Self):
        self.total_lookups = copy.total_lookups
        self.total_inserts = copy.total_inserts
        self.total_updates = copy.total_updates
        self.total_probes = copy.total_probes
        self.max_probe_run = copy.max_probe_run

    fn __moveinit__(out self, deinit take: Self):
        self.total_lookups = take.total_lookups
        self.total_inserts = take.total_inserts
        self.total_updates = take.total_updates
        self.total_probes = take.total_probes
        self.max_probe_run = take.max_probe_run

@fieldwise_init
struct PerfectStationMap[TRACK_METRICS: Bool = False](Copyable, Movable):
    comptime CAPACITY: Int = {size}
    var entries: List[StationStats]
    var occupied: List[Bool]
    var size: Int
    var ptrs: List[UnsafePointer[UInt8, MutExternalOrigin]]
    var lengths: List[Int]
    var metrics: MapMetrics

    fn __init__(out self):
        self.entries = List[StationStats](capacity=Self.CAPACITY)
        self.occupied = List[Bool](capacity=Self.CAPACITY)
        self.ptrs = List[UnsafePointer[UInt8, MutExternalOrigin]](capacity=Self.CAPACITY)
        self.lengths = List[Int](capacity=Self.CAPACITY)
        self.size = 0
        self.metrics = MapMetrics()
        
        for _ in range(Self.CAPACITY):
            self.entries.append(StationStats(0))
            self.entries[-1].count = 0
            self.occupied.append(False)
            self.ptrs.append(UnsafePointer[UInt8, MutExternalOrigin]())
            self.lengths.append(0)

    fn __copyinit__(out self, copy: Self):
        self.entries = copy.entries.copy()
        self.occupied = copy.occupied.copy()
        self.ptrs = copy.ptrs.copy()
        self.lengths = copy.lengths.copy()
        self.size = copy.size
        self.metrics = copy.metrics.copy()

    fn __moveinit__(out self, deinit take: Self):
        self.entries = take.entries^
        self.occupied = take.occupied^
        self.ptrs = take.ptrs^
        self.lengths = take.lengths^
        self.size = take.size
        self.metrics = take.metrics^

    @always_inline
    fn update_or_insert(
        mut self,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
        temp: Int,
    ):
        comptime if Self.TRACK_METRICS:
            self.metrics.total_lookups += 1

        var k = UInt64(length)
        if length > 0:
            k |= (UInt64(ptr[0]) << 8)
            if length > 1:
                k |= (UInt64(ptr[1]) << 16)
                if length > 2:
                    k |= (UInt64(ptr[2]) << 24)
                    if length > 3:
                        k |= (UInt64(ptr[3]) << 32)
                        
            k |= (UInt64(ptr[length-1]) << 40)
            if length > 1:
                k |= (UInt64(ptr[length-2]) << 48)
                if length > 2:
                    k |= (UInt64(ptr[length-3]) << 56)

        comptime MULTIPLIER: UInt64 = {m}
        comptime SHIFT: UInt64 = {shift}
        
        var idx = Int((k * MULTIPLIER) >> SHIFT)
        
        var entries_ptr = self.entries.unsafe_ptr()
        if entries_ptr[idx].count > 0:
            entries_ptr[idx].update(temp)
            comptime if Self.TRACK_METRICS:
                self.metrics.total_updates += 1
        else:
            entries_ptr[idx] = StationStats(temp)
            var occ_ptr = self.occupied.unsafe_ptr()
            occ_ptr[idx] = True
            var ptrs_ptr = self.ptrs.unsafe_ptr()
            ptrs_ptr[idx] = ptr
            var str_len_ptr = self.lengths.unsafe_ptr()
            str_len_ptr[idx] = length
            self.size += 1
            comptime if Self.TRACK_METRICS:
                self.metrics.total_inserts += 1

    fn update_from_stats(
        mut self,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
        incoming: StationStats,
    ):
        var k = UInt64(length)
        if length > 0:
            k |= (UInt64(ptr[0]) << 8)
            if length > 1:
                k |= (UInt64(ptr[1]) << 16)
                if length > 2:
                    k |= (UInt64(ptr[2]) << 24)
                    if length > 3:
                        k |= (UInt64(ptr[3]) << 32)
            k |= (UInt64(ptr[length-1]) << 40)
            if length > 1:
                k |= (UInt64(ptr[length-2]) << 48)
                if length > 2:
                    k |= (UInt64(ptr[length-3]) << 56)

        comptime MULTIPLIER: UInt64 = {m}
        comptime SHIFT: UInt64 = {shift}
        var idx = Int((k * MULTIPLIER) >> SHIFT)
        
        var entries_ptr = self.entries.unsafe_ptr()
        if entries_ptr[idx].count > 0:
            if incoming.min < entries_ptr[idx].min:
                entries_ptr[idx].min = incoming.min
            if incoming.max > entries_ptr[idx].max:
                entries_ptr[idx].max = incoming.max
            entries_ptr[idx].sum += incoming.sum
            entries_ptr[idx].count += incoming.count
        else:
            entries_ptr[idx] = incoming.copy()
            self.occupied[idx] = True
            self.ptrs[idx] = ptr
            self.lengths[idx] = length
            self.size += 1

    fn merge_from(mut self, other: Self):
        for i in range(Self.CAPACITY):
            if other.entries[i].count > 0:
                var ptr = other.ptrs[i]
                var length = other.lengths[i]
                var stats = other.entries[i].copy()
                self.update_from_stats(ptr, length, stats)

    fn print_sorted(self):
        var sorted_keys = List[String](capacity=self.size)
        var slot_indices = List[Int](capacity=self.size)
        
        for i in range(Self.CAPACITY):
            if self.entries[i].count > 0:
                slot_indices.append(i)
                var ptr = self.ptrs[i]
                var length = self.lengths[i]
                var chars = List[UInt8](capacity=length)
                for j in range(length):
                    chars.append(ptr[j])
                sorted_keys.append(String(unsafe_from_utf8=chars))

        for x in range(len(sorted_keys)):
            var min_idx = x
            for y in range(x + 1, len(sorted_keys)):
                if sorted_keys[y] < sorted_keys[min_idx]:
                    min_idx = y
            if min_idx != x:
                var tk = sorted_keys[x]
                sorted_keys[x] = sorted_keys[min_idx]
                sorted_keys[min_idx] = tk
                var ti = slot_indices[x]
                slot_indices[x] = slot_indices[min_idx]
                slot_indices[min_idx] = ti

        print("{{", end="")
        for i in range(len(sorted_keys)):
            var slot = slot_indices[i]
            var stats = self.entries[slot].copy()
            print(sorted_keys[i], end="=")
            print(
                Float64(stats.min) / 10.0,
                "/",
                stats.mean(),
                "/",
                Float64(stats.max) / 10.0,
                end="",
            )
            if i < len(sorted_keys) - 1:
                print(", ", end="")
        print("}}\\n")
"""
    with open('perfect_hashmap.mojo', 'w') as f:
        f.write(mojo_code)
    print("Generated perfect_hashmap.mojo for 413 stations.")
