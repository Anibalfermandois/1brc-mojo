from std.memory import UnsafePointer, alloc
from misc.metrics import MapTracker, MapMetrics, EmptyMapMetrics
from std.sys.intrinsics import likely, unlikely, assume
from .stations_data import (
    PERFECT_MULTIPLIER,
    PERFECT_CAPACITY,
    PERFECT_SHIFT,
    STATION_HASHES,
    STATION_NAMES,
)


@fieldwise_init
struct StationStats(TrivialRegisterPassable, ImplicitlyCopyable):
    var min: Int16
    var max: Int16
    var count: Int32
    var sum: Int64

    def __init__(out self, initial_temp: Int):
        self.min = Int16(initial_temp)
        self.max = Int16(initial_temp)
        self.sum = Int64(initial_temp)
        self.count = 1



    @always_inline
    def update(mut self, temp: Int):
        self.min = min(self.min, Int16(temp))
        self.max = max(self.max, Int16(temp))
        self.sum += Int64(temp)
        self.count += 1

    def mean(self) -> Float64:
        if self.count == 0:
            return 0.0
        return Float64(self.sum) / (Float64(self.count) * 10.0)


@align(64)
struct MapEntry(TrivialRegisterPassable, ImplicitlyCopyable):
    var stats: StationStats  # 16 bytes
    var ptr: UnsafePointer[UInt8, MutUntrackedOrigin]  # 8 bytes
    var length: Int32  # 4 bytes
    var padding: Int32  # 4 bytes
    # Total: 32 bytes

    def __init__(out self):
        self.stats = StationStats(min=999, max=-999, sum=0, count=0)
        self.ptr = UnsafePointer[UInt8, MutUntrackedOrigin].unsafe_dangling()
        self.length = 0
        self.padding = 0

    def __init__(
        out self,
        stats: StationStats,
        ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
        length: Int,
    ):
        self.stats = stats
        self.ptr = ptr
        self.length = Int32(length)
        self.padding = 0


struct PerfectStationMap[
    CAPACITY: Int = PERFECT_CAPACITY,
    MULTIPLIER: UInt64 = PERFECT_MULTIPLIER,
    SHIFT: Int = PERFECT_SHIFT,
    MAP_TRACKER: MapTracker = EmptyMapMetrics,
](Copyable, Movable):
    var data: UnsafePointer[MapEntry, MutUntrackedOrigin]
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

    def __init__(out self, *, deinit move: Self):
        self.data = move.data
        self.size = move.size
        self.metrics = move.metrics^

    def __del__(deinit self):
        self.data.free()

    @always_inline
    def update_or_insert(
        mut self,
        ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
        length: Int,
        temp: Int,
    ):
        assume(length >= 3)
        var head = UInt64(ptr.bitcast[UInt32]().load[alignment=1]())
        var tail_byte = UInt64(ptr[length - 3])
        self.update_or_insert_precomputed(ptr, length, temp, head, tail_byte)

    @always_inline
    def update_or_insert_precomputed(
        mut self,
        ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
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
        ref entry = self.data[idx]
        if unlikely(entry.stats.count == 0):
            entry.ptr = ptr
            entry.length = Int32(length)
            self.size += 1
            comptime if Self.MAP_TRACKER.ACTIVE:
                self.metrics.record_insert()
        comptime if Self.MAP_TRACKER.ACTIVE:
            if entry.stats.count > 0:
                self.metrics.record_update()
        entry.stats.update(temp)

    def update_from_stats(
        mut self,
        ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
        length: Int,
        read incoming: StationStats,
    ):
        assume(length >= 3)
        var head = UInt64(ptr.bitcast[UInt32]().load[alignment=1]())
        var val = UInt64(length)
        val |= (head & 0xFFFFFF) << 8
        val |= UInt64(ptr[length - 3]) << 32

        var idx = Int((val * Self.MULTIPLIER) >> UInt64(Self.SHIFT))

        ref entry = self.data[idx]
        if entry.stats.count > 0:
            var stats = entry.stats
            if Int32(incoming.min) < Int32(stats.min):
                stats.min = incoming.min
            if Int32(incoming.max) > Int32(stats.max):
                stats.max = incoming.max
            stats.sum += incoming.sum
            stats.count += incoming.count
            entry.stats = stats
        else:
            entry = MapEntry(incoming, ptr, length)
            self.size += 1

    def merge_from(mut self, imm other: Self):
        comptime if Self.MAP_TRACKER.ACTIVE:
            self.metrics.merge_from(other.metrics)
        for i in range(Self.CAPACITY):
            ref entry = other.data[i]
            if entry.stats.count > 0:
                ref target = self.data[i]
                if target.stats.count > 0:
                    var stats = target.stats
                    if Int32(entry.stats.min) < Int32(stats.min):
                        stats.min = entry.stats.min
                    if Int32(entry.stats.max) > Int32(stats.max):
                        stats.max = entry.stats.max
                    stats.sum += entry.stats.sum
                    stats.count += entry.stats.count
                    target.stats = stats
                else:
                    # The input pointer may refer to a reusable streaming
                    # buffer, so only copy aggregate values across maps.
                    target.stats = entry.stats
                    self.size += 1

    def print_sorted(self):
        var sorted_keys = List[String](capacity=self.size)
        var slot_indices = List[Int](capacity=self.size)
        comptime for station_index in range(len(STATION_NAMES)):
            comptime station_hash = UInt64(STATION_HASHES[station_index])
            comptime slot = Int(
                (station_hash * Self.MULTIPLIER) >> UInt64(Self.SHIFT)
            )
            if self.data[slot].stats.count > 0:
                slot_indices.append(slot)
                sorted_keys.append(String(STATION_NAMES[station_index]))
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
        print("{", end="")
        for i in range(len(sorted_keys)):
            var slot = slot_indices[i]
            var stats = self.data[slot].stats
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
        print("}\n")
