from std.memory import UnsafePointer, alloc
from misc.metrics import MapTracker, MapMetrics, EmptyMapMetrics
from std.sys.intrinsics import likely, unlikely, assume
from .stations_data import PERFECT_MULTIPLIER, PERFECT_CAPACITY, PERFECT_SHIFT

@fieldwise_init
struct StationStats(Copyable, ImplicitlyCopyable, Movable):
    var sum: Int
    var count: Int32
    var min: Int16
    var max: Int16

    def __init__(out self, initial_temp: Int):
        self.sum = initial_temp
        self.count = 1
        self.min = Int16(initial_temp)
        self.max = Int16(initial_temp)

    def __init__(out self, *, copy: Self):
        self.sum = copy.sum
        self.count = copy.count
        self.min = copy.min
        self.max = copy.max

    def __init__(out self, *, deinit take: Self):
        self.sum = take.sum
        self.count = take.count
        self.min = take.min
        self.max = take.max

    @always_inline
    def update(mut self, temp: Int):
        var t16 = Int16(temp)
        if unlikely(t16 < self.min):
            self.min = t16
        if unlikely(t16 > self.max):
            self.max = t16
        self.sum += temp
        self.count += 1

    def mean(self) -> Float64:
        if self.count == 0:
            return 0.0
        return Float64(self.sum) / (Float64(self.count) * 10.0)

struct MapEntry(Copyable, ImplicitlyCopyable, Movable):
    var stats: StationStats # 32 bytes
    var ptr: UnsafePointer[UInt8, MutExternalOrigin] # 8 bytes
    var signature: UInt32 # 4 bytes
    var length: Int32 # 4 bytes
    # Total: 48 bytes

    def __init__(out self):
        self.stats = StationStats(min=999, max= -999, sum=0, count=0)
        self.ptr = UnsafePointer[UInt8, MutExternalOrigin]()
        self.signature = 0
        self.length = 0

    def __init__(
        out self,
        stats: StationStats,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
        signature: UInt32,
    ):
        self.stats = stats
        self.ptr = ptr
        self.signature = signature
        self.length = Int32(length)

struct PerfectStationMap[
    CAPACITY: Int = PERFECT_CAPACITY,
    MULTIPLIER: UInt64 = PERFECT_MULTIPLIER,
    SHIFT: Int = PERFECT_SHIFT,
    MAP_TRACKER: MapTracker = EmptyMapMetrics,
](Copyable, Movable):
    var data: UnsafePointer[MapEntry, MutExternalOrigin]
    var size: Int
    var metrics: Self.MAP_TRACKER

    def __init__(out self):
        self.data = alloc[MapEntry](Self.CAPACITY)
        self.size = 0
        self.metrics = Self.MAP_TRACKER()
        for i in range(Self.CAPACITY):
            self.data[i] = MapEntry()

    def __init__(out self, *, copy: Self):
        self.data = alloc[MapEntry](Self.CAPACITY)
        comptime for i in range(Self.CAPACITY):
            self.data[i] = copy.data[i]
        self.size = copy.size
        self.metrics = copy.metrics

    def __init__(out self, *, deinit take: Self):
        self.data = take.data
        self.size = take.size
        self.metrics = take.metrics^

    @always_inline
    def update_or_insert(
        mut self,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
        temp: Int,
    ):
        assume(length >= 3)
        var head = UInt64(ptr.bitcast[UInt32]().load())
        var tail_byte = UInt64(ptr[length - 3])
        self.update_or_insert_precomputed(ptr, length, temp, head, tail_byte)

    @always_inline
    def update_or_insert_precomputed(
        mut self,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
        temp: Int,
        head: UInt64,
        tail_byte: UInt64,
    ):
        comptime if Self.MAP_TRACKER.ACTIVE:
            self.metrics.record_lookup()

        var val = UInt64(length)
        val |= (head & 0xFFFFFF) << 8
        val |= tail_byte << 32

        var idx = Int((val * Self.MULTIPLIER) >> UInt64(Self.SHIFT))
        assume(idx >= 0)
        assume(idx < Self.CAPACITY)

        # Perfect hash: unconditional stats update.
        # ptr/length set only on first encounter (413 times out of 1B rows).
        if unlikely(self.data[idx].stats.count == 0):
            self.data[idx].ptr = ptr
            self.data[idx].length = Int32(length)
            self.size += 1
            comptime if Self.MAP_TRACKER.ACTIVE:
                self.metrics.record_insert()
        comptime if Self.MAP_TRACKER.ACTIVE:
            if self.data[idx].stats.count > 0:
                self.metrics.record_update()
        self.data[idx].stats.update(temp)

    def update_from_stats(
        mut self,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
        read incoming: StationStats,
    ):
        assume(length >= 3)
        var head = UInt64(ptr.bitcast[UInt32]().load())
        var val = UInt64(length)
        val |= (head & 0xFFFFFF) << 8
        val |= UInt64(ptr[length - 3]) << 32

        var idx = Int((val * Self.MULTIPLIER) >> UInt64(Self.SHIFT))

        if self.data[idx].stats.count > 0:
            if incoming.min < self.data[idx].stats.min:
                self.data[idx].stats.min = incoming.min
            if incoming.max > self.data[idx].stats.max:
                self.data[idx].stats.max = incoming.max
            self.data[idx].stats.sum += incoming.sum
            self.data[idx].stats.count += incoming.count
        else:
            self.data[idx] = MapEntry(incoming, ptr, length, UInt32(0))
            self.size += 1

    def merge_from(mut self, read other: Self):
        comptime if Self.MAP_TRACKER.ACTIVE:
            self.metrics.merge_from(other.metrics)
        for i in range(Self.CAPACITY):
            ref entry = other.data[i]
            if entry.stats.count > 0:
                self.update_from_stats(entry.ptr, Int(entry.length), entry.stats)

    def print_sorted(self):
        var sorted_keys = List[String](capacity=self.size)
        var slot_indices = List[Int](capacity=self.size)
        for i in range(Self.CAPACITY):
            if self.data[i].stats.count > 0:
                slot_indices.append(i)
                ref entry = self.data[i]
                var chars = List[UInt8](capacity=Int(entry.length))
                for j in range(Int(entry.length)):
                    chars.append(entry.ptr[j])
                sorted_keys.append(String(unsafe_from_utf8=chars))
        for x in range(len(sorted_keys)):
            var min_idx = x
            for y in range(x + 1, len(sorted_keys)):
                if sorted_keys[y] < sorted_keys[min_idx]:
                    min_idx = y
            if min_idx != x:
                var tk = sorted_keys[x]; sorted_keys[x] = sorted_keys[min_idx]; sorted_keys[min_idx] = tk
                var ti = slot_indices[x]; slot_indices[x] = slot_indices[min_idx]; slot_indices[min_idx] = ti
        print("{", end="")
        for i in range(len(sorted_keys)):
            var slot = slot_indices[i]
            var stats = self.data[slot].stats
            print(sorted_keys[i], end="=")
            print(Float64(stats.min) / 10.0, "/", stats.mean(), "/", Float64(stats.max) / 10.0, end="")
            if i < len(sorted_keys) - 1: print(", ", end="")
        print("}\n")
