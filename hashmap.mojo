from std.memory import UnsafePointer

comptime MAX_STATIONS: Int = 10000


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


@fieldwise_init
struct MapEntry(Copyable, Movable):
    var ptr: UnsafePointer[UInt8, MutExternalOrigin]
    var length: Int
    var stats: StationStats

    fn __init__(out self):
        self.ptr = UnsafePointer[UInt8, MutExternalOrigin]()
        self.length = 0
        self.stats = StationStats(0)

    fn __copyinit__(out self, copy: Self):
        self.ptr = copy.ptr
        self.length = copy.length
        self.stats = copy.stats.copy()

    fn __moveinit__(out self, deinit take: Self):
        self.ptr = take.ptr
        self.length = take.length
        self.stats = take.stats^


# ── Metrics Struct ─────────────────────────────────────────────────────────────
# Collected per-map and reported by analyze.mojo.  Zero cost when the
# containing FastStationMap is instantiated with TRACK_METRICS=False.
struct MapMetrics(Copyable, Movable):
    var total_lookups: Int  # Every call to update_or_insert
    var total_inserts: Int  # New station slots created
    var total_updates: Int  # Hits on existing slots
    var total_probes: Int  # Extra slots checked beyond the first
    var max_probe_run: Int  # Worst-case probe-chain length seen

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


@always_inline
fn station_hash(
    ptr: UnsafePointer[UInt8, MutExternalOrigin], length: Int
) -> UInt64:
    """O(1) XOR-fold hash: XOR the first and last 8 bytes of the name,
    multiply by a Fibonacci hashing constant. This is O(1) regardless of name
    length and provides a good distribution because station names differ both
    in prefix (first 8 bytes) and suffix (last 8 bytes).
    For names < 8 bytes we fall back to a simple byte-by-byte hash.
    """
    comptime MAGIC: UInt64 = 0x9E3779B97F4A7C15  # Fibonacci hashing constant
    if length >= 8:
        var head = ptr.bitcast[UInt64]()[]
        var tail = (ptr + length - 8).bitcast[UInt64]()[]
        return (head ^ tail ^ UInt64(length)) * MAGIC

    # Short-name fallback (<8 bytes)
    var v: UInt64 = UInt64(length)
    for i in range(length):
        v = (v << 5) ^ UInt64(ptr[i])
    return v * MAGIC


struct FastStationMap[TRACK_METRICS: Bool = False](Copyable, Movable):
    # At 16384 slots: 16384 × 48B = 768 KB → fits in M3 L2 cache cluster.
    # Load factor ~2.5% → practically zero collision chains.
    comptime CAPACITY: Int = 16384
    var entries: List[MapEntry]
    var size: Int
    # Optional metrics — only present when TRACK_METRICS=True.
    # The comptime if blocks ensure the compiler elides these fields
    # entirely in production builds.
    var metrics: MapMetrics

    fn __init__(out self):
        self.entries = List[MapEntry](capacity=Self.CAPACITY)
        self.size = 0
        self.metrics = MapMetrics()

        for i in range(Self.CAPACITY):
            self.entries.append(MapEntry())

    fn __copyinit__(out self, copy: Self):
        self.entries = copy.entries.copy()
        self.size = copy.size
        self.metrics = copy.metrics.copy()

    fn __moveinit__(out self, deinit take: Self):
        self.entries = take.entries^
        self.size = take.size
        self.metrics = take.metrics^

    fn _find_slot(
        mut self,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
        hash_val: UInt64,
    ) -> Int:
        var idx = Int(hash_val & UInt64(Self.CAPACITY - 1))
        var probe_run = 0

        while self.entries[idx].length > 0:
            var existing_len = self.entries[idx].length
            if existing_len == length:
                var is_match = True
                var eptr = self.entries[idx].ptr
                for i in range(length):
                    if eptr[i] != ptr[i]:
                        is_match = False
                        break
                if is_match:
                    comptime if Self.TRACK_METRICS:
                        self.metrics.total_probes += probe_run
                        if probe_run > self.metrics.max_probe_run:
                            self.metrics.max_probe_run = probe_run
                    return idx

            idx = (idx + 1) & (Self.CAPACITY - 1)
            probe_run += 1

        comptime if Self.TRACK_METRICS:
            self.metrics.total_probes += probe_run
            if probe_run > self.metrics.max_probe_run:
                self.metrics.max_probe_run = probe_run

        return idx

    fn update_or_insert(
        mut self,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
        temp: Int,
    ):
        comptime if Self.TRACK_METRICS:
            self.metrics.total_lookups += 1

        var hash_val = station_hash(ptr, length)
        var idx = self._find_slot(ptr, length, hash_val)
        var entries_ptr = self.entries.unsafe_ptr()

        if entries_ptr[idx].length > 0:
            entries_ptr[idx].stats.update(temp)

            comptime if Self.TRACK_METRICS:
                self.metrics.total_updates += 1
        else:
            var entry = MapEntry()
            entry.ptr = ptr
            entry.length = length
            entry.stats = StationStats(temp)
            entries_ptr[idx] = entry^
            self.size += 1

            comptime if Self.TRACK_METRICS:
                self.metrics.total_inserts += 1

    fn update_from_stats(
        mut self,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
        incoming: StationStats,
    ):
        """Merge pre-aggregated stats for one station into this map.

        Used by merge_from() to combine per-thread results without
        re-iterating individual temperature values.
        """
        var hash_val = station_hash(ptr, length)
        var idx = self._find_slot(ptr, length, hash_val)
        var entries_ptr = self.entries.unsafe_ptr()

        if entries_ptr[idx].length > 0:
            if incoming.min < entries_ptr[idx].stats.min:
                entries_ptr[idx].stats.min = incoming.min
            if incoming.max > entries_ptr[idx].stats.max:
                entries_ptr[idx].stats.max = incoming.max
            entries_ptr[idx].stats.sum += incoming.sum
            entries_ptr[idx].stats.count += incoming.count
        else:
            var entry = MapEntry()
            entry.ptr = ptr
            entry.length = length
            entry.stats = incoming.copy()
            entries_ptr[idx] = entry^
            self.size += 1

    fn merge_from(mut self, other: Self):
        """Merge all stations from `other` into this map.

        Call this after all threads have finished to combine their
        per-thread FastStationMap results into a single global map.
        """
        for i in range(Self.CAPACITY):
            if other.entries[i].length > 0:
                var ptr = other.entries[i].ptr
                var length = other.entries[i].length
                var stats = other.entries[i].stats.copy()
                self.update_from_stats(ptr, length, stats)

    fn print_sorted(self):
        # Collect (slot_index, key) pairs for all occupied slots
        var slot_indices = List[Int](capacity=self.size)
        var sorted_keys = List[String](capacity=self.size)
        for i in range(Self.CAPACITY):
            if self.entries[i].length > 0:
                slot_indices.append(i)
                var ptr = self.entries[i].ptr
                var length = self.entries[i].length
                var chars = List[UInt8](capacity=length)
                for j in range(length):
                    chars.append(ptr[j])
                sorted_keys.append(String(unsafe_from_utf8=chars))

        # Selection sort by key string
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

        # Print — use slot_indices directly so no re-lookup is needed
        print("{", end="")
        for i in range(len(sorted_keys)):
            var slot = slot_indices[i]
            var stats = self.entries[slot].stats.copy()
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
