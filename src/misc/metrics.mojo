from std.memory import UnsafePointer

# ── Map Analysis ──────────────────────────────────────────────

trait MapTracker(Copyable, ImplicitlyCopyable, Movable):
    comptime ACTIVE: Bool
    def __init__(out self): ...
    def record_lookup(mut self): ...
    def record_insert(mut self): ...
    def record_update(mut self): ...
    def record_probe(mut self): ...
    def record_max_probe(mut self, run: Int): ...
    def get_total_lookups(self) -> Int: ...
    def get_total_inserts(self) -> Int: ...
    def get_total_updates(self) -> Int: ...
    def get_total_probes(self) -> Int: ...
    def get_max_probe_run(self) -> Int: ...
    def print_summary(self): ...
    def merge_from(mut self, read other: Self): ...

struct MapMetrics(MapTracker, Copyable, ImplicitlyCopyable, Movable):
    comptime ACTIVE = True
    var total_lookups: Int
    var total_inserts: Int
    var total_updates: Int
    var total_probes: Int
    var max_probe_run: Int

    def __init__(out self):
        self.total_lookups = 0
        self.total_inserts = 0
        self.total_updates = 0
        self.total_probes = 0
        self.max_probe_run = 0

    @always_inline
    def record_lookup(mut self): self.total_lookups += 1
    @always_inline
    def record_insert(mut self): self.total_inserts += 1
    @always_inline
    def record_update(mut self): self.total_updates += 1
    @always_inline
    def record_probe(mut self): self.total_probes += 1
    @always_inline
    def record_max_probe(mut self, run: Int):
        if run > self.max_probe_run: self.max_probe_run = run

    def get_total_lookups(self) -> Int: return self.total_lookups
    def get_total_inserts(self) -> Int: return self.total_inserts
    def get_total_updates(self) -> Int: return self.total_updates
    def get_total_probes(self) -> Int: return self.total_probes
    def get_max_probe_run(self) -> Int: return self.max_probe_run

    def print_summary(self):
        if self.total_probes > 0:
            print("\n── Perfect Hashmap Collision Verification ───────────────────────────")
            print("  Total Lookups:  ", self.total_lookups)
            print("  [!] WARNING: Collisions detected! Total Probes:", self.total_probes)
            print("  Max probe run:  ", self.max_probe_run)
            print("  This means your PerfectStationMap multiplier/shift failed for this dataset.")
        else:
            print("\n── Perfect Hashmap Collision Verification ───────────────────────────")
            print("  Total Lookups:  ", self.total_lookups)
            print("  Status: Perfect! No collisions detected.")

    def merge_from(mut self, read other: Self):
        self.total_lookups += other.total_lookups
        self.total_inserts += other.total_inserts
        self.total_updates += other.total_updates
        self.total_probes += other.total_probes
        if other.max_probe_run > self.max_probe_run:
            self.max_probe_run = other.max_probe_run

struct EmptyMapMetrics(MapTracker, Copyable, ImplicitlyCopyable, Movable):
    comptime ACTIVE = False
    def __init__(out self): pass
    @always_inline
    def record_lookup(mut self): pass
    @always_inline
    def record_insert(mut self): pass
    @always_inline
    def record_update(mut self): pass
    @always_inline
    def record_probe(mut self): pass
    @always_inline
    def record_max_probe(mut self, run: Int): pass
    def get_total_lookups(self) -> Int: return 0
    def get_total_inserts(self) -> Int: return 0
    def get_total_updates(self) -> Int: return 0
    def get_total_probes(self) -> Int: return 0
    def get_max_probe_run(self) -> Int: return 0
    def print_summary(self): pass
    def merge_from(mut self, read other: Self): pass

# ── Parser Analysis ───────────────────────────────────────────

trait ParserTracker(Copyable, Movable, ImplicitlyCopyable):
    comptime ACTIVE: Bool
    def __init__(out self): ...
    def record_simd_iteration(mut self): ...
    def record_simd_hit(mut self): ...
    def record_row_simd(mut self): ...
    def record_row_tail(mut self): ...
    def record_name(mut self, length: Int): ...
    def record_missed_block(mut self, block: String): ...
    def get_simd_iterations(self) -> Int: ...
    def get_simd_hits(self) -> Int: ...
    def get_rows_simd(self) -> Int: ...
    def get_rows_tail(self) -> Int: ...
    def get_total_name_len(self) -> Int: ...
    def get_max_name_len(self) -> Int: ...
    def get_missed_blocks(self) -> List[String]: ...
    def print_summary(self, size: Int, parse_s: Float64): ...
    def merge_from(mut self, read other: Self): ...

struct ParserMetrics(Copyable, Movable, ParserTracker):
    comptime ACTIVE = True
    var simd_iterations: Int
    var simd_hits: Int
    var rows_simd: Int
    var rows_tail: Int
    var total_name_len: Int
    var max_name_len: Int
    var missed_blocks: List[String]

    def __init__(out self):
        self.simd_iterations = 0
        self.simd_hits = 0
        self.rows_simd = 0
        self.rows_tail = 0
        self.total_name_len = 0
        self.max_name_len = 0
        self.missed_blocks = List[String]()

    def __init__(out self, *, copy: Self):
        self.simd_iterations = copy.simd_iterations
        self.simd_hits = copy.simd_hits
        self.rows_simd = copy.rows_simd
        self.rows_tail = copy.rows_tail
        self.total_name_len = copy.total_name_len
        self.max_name_len = copy.max_name_len
        self.missed_blocks = copy.missed_blocks.copy()

    def __init__(out self, *, deinit take: Self):
        self.simd_iterations = take.simd_iterations
        self.simd_hits = take.simd_hits
        self.rows_simd = take.rows_simd
        self.rows_tail = take.rows_tail
        self.total_name_len = take.total_name_len
        self.max_name_len = take.max_name_len
        self.missed_blocks = take.missed_blocks^

    @always_inline
    def record_simd_iteration(mut self):
        self.simd_iterations += 1

    @always_inline
    def record_simd_hit(mut self):
        self.simd_hits += 1

    @always_inline
    def record_row_simd(mut self):
        self.rows_simd += 1

    @always_inline
    def record_row_tail(mut self):
        self.rows_tail += 1

    @always_inline
    def record_name(mut self, length: Int):
        self.total_name_len += length
        if length > self.max_name_len:
            self.max_name_len = length

    @always_inline
    def record_missed_block(mut self, block: String):
        if len(self.missed_blocks) < 5:
            self.missed_blocks.append(block)

    def get_simd_iterations(self) -> Int:
        return self.simd_iterations

    def get_simd_hits(self) -> Int:
        return self.simd_hits

    def get_rows_simd(self) -> Int:
        return self.rows_simd

    def get_rows_tail(self) -> Int:
        return self.rows_tail

    def get_total_name_len(self) -> Int:
        return self.total_name_len

    def get_max_name_len(self) -> Int:
        return self.max_name_len

    def get_missed_blocks(self) -> List[String]:
        return self.missed_blocks.copy()

    def print_summary(self, size: Int, parse_s: Float64):
        var actual_rows = self.rows_simd + self.rows_tail
        var actual_tput = Float64(actual_rows) / parse_s / 1_000_000.0
        var actual_gb_s = Float64(size) / parse_s / (1024 * 1024 * 1024)

        print("\n── Parser Metrics (`parse_chunk`) ───────────────────────────────────")
        print("  Actual Parsed Rows: ", actual_rows)
        print("  Throughput:         ", actual_tput, " M rows/s (", actual_gb_s, " GB/s)")
        print("  Avg Row Length: ", Float64(size) / max(Float64(actual_rows), 1.0), " bytes")
        print("  Avg Name Len:   ", Float64(self.total_name_len) / max(Float64(actual_rows), 1.0), " bytes")
        print("  Max Name Len:   ", self.max_name_len, " bytes")
        print("  SIMD Iterations:", self.simd_iterations)
        var hit_pct = Float64(self.simd_hits) / max(Float64(self.simd_iterations), 1.0) * 100.0
        print("  SIMD Hits:      ", self.simd_hits, " (", hit_pct, "% of 16-byte blocks had a newline)")
        print("  Rows via SIMD:  ", self.rows_simd)
        print("  Rows via Tail:  ", self.rows_tail)

        if len(self.missed_blocks) > 0:
            print("\n── SIMD Miss Samples (Blocks with no newlines) ──────────────────────")
            for i in range(len(self.missed_blocks)):
                print("  Sample ", i + 1, ": [", self.missed_blocks[i], "]")

    def merge_from(mut self, read other: Self):
        self.simd_iterations += other.simd_iterations
        self.simd_hits += other.simd_hits
        self.rows_simd += other.rows_simd
        self.rows_tail += other.rows_tail
        self.total_name_len += other.total_name_len
        if other.max_name_len > self.max_name_len:
            self.max_name_len = other.max_name_len
        for i in range(len(other.missed_blocks)):
            self.record_missed_block(other.missed_blocks[i])


struct EmptyParserMetrics(Copyable, Movable, ParserTracker):
    comptime ACTIVE = False
    def __init__(out self):
        pass

    @always_inline
    def record_simd_iteration(mut self):
        pass

    @always_inline
    def record_simd_hit(mut self):
        pass

    @always_inline
    def record_row_simd(mut self):
        pass

    @always_inline
    def record_row_tail(mut self):
        pass

    @always_inline
    def record_name(mut self, length: Int):
        pass

    @always_inline
    def record_missed_block(mut self, block: String):
        pass

    def get_simd_iterations(self) -> Int:
        return 0

    def get_simd_hits(self) -> Int:
        return 0

    def get_rows_simd(self) -> Int:
        return 0

    def get_rows_tail(self) -> Int:
        return 0

    def get_total_name_len(self) -> Int:
        return 0

    def get_max_name_len(self) -> Int:
        return 0

    def get_missed_blocks(self) -> List[String]:
        return List[String]()

    def print_summary(self, size: Int, parse_s: Float64):
        pass

    def merge_from(mut self, read other: Self):
        pass
