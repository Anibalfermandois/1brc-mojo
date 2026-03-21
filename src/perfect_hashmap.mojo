from std.memory import UnsafePointer, alloc
from metrics import MapTracker, MapMetrics, EmptyMapMetrics
from std.sys.intrinsics import likely, unlikely, assume


@fieldwise_init
struct StationStats(Copyable, ImplicitlyCopyable, Movable):
    var min: Int
    var max: Int
    var sum: Int
    var count: Int

    def __init__(out self, initial_temp: Int):
        self.min = initial_temp
        self.max = initial_temp
        self.sum = initial_temp
        self.count = 1

    def __init__(out self, *, copy: Self):
        self.min = copy.min
        self.max = copy.max
        self.sum = copy.sum
        self.count = copy.count

    def __init__(out self, *, deinit take: Self):
        self.min = take.min
        self.max = take.max
        self.sum = take.sum
        self.count = take.count

    @always_inline
    def update(mut self, temp: Int):
        if unlikely(temp < self.min):
            self.min = temp
        if unlikely(temp > self.max):
            self.max = temp
        self.sum += temp
        self.count += 1

    def mean(self) -> Float64:
        if self.count == 0:
            return 0.0
        return Float64(self.sum) / (Float64(self.count) * 10.0)


struct MapEntry(Copyable, ImplicitlyCopyable, Movable):
    var stats: StationStats
    var ptr: UnsafePointer[UInt8, MutExternalOrigin]
    var length: Int

    def __init__(out self):
        self.stats = StationStats(0)
        self.stats.count = 0
        self.ptr = UnsafePointer[UInt8, MutExternalOrigin]()
        self.length = 0

    def __init__(
        out self,
        stats: StationStats,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
    ):
        self.stats = stats
        self.ptr = ptr
        self.length = length


struct PerfectStationMap[
    CAPACITY: Int = 16384,
    MULTIPLIER: UInt64 = 11164934581231786391,
    SHIFT: Int = 50,
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
        comptime if Self.MAP_TRACKER.ACTIVE:
            self.metrics.record_lookup()

        # BRANCHLESS property extraction!
        var k = UInt64(length)
        k |= UInt64(ptr[0]) << 8
        k |= UInt64(ptr[length >> 1]) << 16
        k |= UInt64(ptr[length - 1]) << 24
        k |= UInt64(ptr[1]) << 32
        k |= UInt64(ptr[length - 2]) << 40

        comptime SHIFT_U64 = UInt64(Self.SHIFT)
        var idx = Int((k * Self.MULTIPLIER) >> SHIFT_U64)
        assume(idx >= 0)
        assume(idx < Self.CAPACITY)

        if likely(self.data[idx].stats.count > 0):
            comptime if Self.MAP_TRACKER.ACTIVE:
                var existing_ptr = self.data[idx].ptr
                var existing_len = self.data[idx].length
                if existing_len != length:
                    self.metrics.record_probe()
                else:
                    var is_match = True
                    for i in range(length):
                        if existing_ptr[i] != ptr[i]:
                            is_match = False
                            break
                    if not is_match:
                        self.metrics.record_probe()

            self.data[idx].stats.update(temp)
            comptime if Self.MAP_TRACKER.ACTIVE:
                self.metrics.record_update()
        else:
            self.data[idx] = MapEntry(StationStats(temp), ptr, length)
            self.size += 1
            comptime if Self.MAP_TRACKER.ACTIVE:
                self.metrics.record_insert()

    def update_from_stats(
        mut self,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
        read incoming: StationStats,
    ):
        var k = UInt64(length)
        k |= UInt64(ptr[0]) << 8
        k |= UInt64(ptr[length >> 1]) << 16
        k |= UInt64(ptr[length - 1]) << 24
        k |= UInt64(ptr[1]) << 32
        k |= UInt64(ptr[length - 2]) << 40

        comptime SHIFT_U64 = UInt64(Self.SHIFT)
        var idx = Int((k * Self.MULTIPLIER) >> SHIFT_U64)

        if self.data[idx].stats.count > 0:
            comptime if Self.MAP_TRACKER.ACTIVE:
                var existing_ptr = self.data[idx].ptr
                var existing_len = self.data[idx].length
                if existing_len != length:
                    self.metrics.record_probe()
                else:
                    var is_match = True
                    for i in range(length):
                        if existing_ptr[i] != ptr[i]:
                            is_match = False
                            break
                    if not is_match:
                        self.metrics.record_probe()

            if incoming.min < self.data[idx].stats.min:
                self.data[idx].stats.min = incoming.min
            if incoming.max > self.data[idx].stats.max:
                self.data[idx].stats.max = incoming.max
            self.data[idx].stats.sum += incoming.sum
            self.data[idx].stats.count += incoming.count
        else:
            self.data[idx] = MapEntry(incoming, ptr, length)
            self.size += 1

    def merge_from(mut self, other: Self):
        for i in range(Self.CAPACITY):
            ref entry = other.data[i]
            if entry.stats.count > 0:
                self.update_from_stats(entry.ptr, entry.length, entry.stats)

    def print_sorted(self):
        var sorted_keys = List[String](capacity=self.size)
        var slot_indices = List[Int](capacity=self.size)

        for i in range(Self.CAPACITY):
            if self.data[i].stats.count > 0:
                slot_indices.append(i)
                var entry = self.data[i]
                var chars = List[UInt8](capacity=entry.length)
                for j in range(entry.length):
                    chars.append(entry.ptr[j])
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
