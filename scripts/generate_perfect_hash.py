import sys
import random

# The exactly 24 stations from generate_data.py
STATIONS = [
    "Hamburg", "Bulawayo", "Tauranga", "Albert Town",
    "Acapulco", "Omsk", "Washington, D.C.", "Dushanbe",
    "Zhengzhou", "Nouakchott", "Reno", "Phuket",
    "Tokyo", "Rio de Janeiro", "Sydney", "New York City",
    "London", "Paris", "Berlin", "Moscow",
    "Beijing", "Mumbai", "Cairo", "Cape Town"
]

def string_to_int(s):
    """
    Simulate the Mojo fallback byte-by-byte hash OR the first/last XOR hash.
    Actually, let's keep it simple: we can do a very simple mathematical operation.
    In Mojo, we can easily read the first 4 or 8 bytes as an integer, or just use length + first char + last char.
    Let's find *any* property of these 24 strings that makes them unique,
    then we find a multiplier `M` and shift `S` such that (val * M) >>> S maps perfectly to [0...23].
    """
    # A simple and extremely fast hash: length + (first_byte << 8) + (last_byte << 16)
    b = s.encode('utf-8')
    return len(b) + (b[0] << 8) + (b[-1] << 16)

def find_perfect_hash():
    keys = STATIONS
    int_keys = [string_to_int(s) for s in keys]
    
    # Sanity check: our base property must be unique across all 24
    assert len(set(int_keys)) == 24, "Base string-to-int property has a collision!"
    
    table_size = 32 # Needs to be power of 2 for fast `& (size-1)` modulo. 
    # Or we can just use capacity=32 and map into it.
    
    # Try random multipliers until we find one with no collisions when taking modulo 32
    mask = table_size - 1
    attempts = 0
    while True:
        attempts += 1
        m = random.getrandbits(64) | 1 # Odd multiplier
        shift = 64 - 5 # 32 is 2^5, so shift by 59 to get top 5 bits
        
        # Test if M works
        indices = set()
        collision = False
        for k in int_keys:
            # Mojo uint64 multiply and shift right
            idx = ((k * m) & 0xFFFFFFFFFFFFFFFF) >> shift
            if idx in indices:
                collision = True
                break
            indices.add(idx)
            
        if not collision:
            print(f"Found perfect hash multiplier: {hex(m)} after {attempts} attempts")
            return m, shift, table_size

if __name__ == "__main__":
    m, shift, size = find_perfect_hash()
    
    # Generate the string to value map to embed in Mojo
    mapped = {}
    for s in STATIONS:
        k = string_to_int(s)
        idx = ((k * m) & 0xFFFFFFFFFFFFFFFF) >> shift
        mapped[idx] = s

    print("Mapping:")
    for idx in range(size):
        if idx in mapped:
            print(f"  [{idx}] = {mapped[idx]}")
        else:
            print(f"  [{idx}] = empty")
    
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

@fieldwise_init
struct PerfectStationMap(Copyable, Movable):
    comptime CAPACITY: Int = {size}
    # An inline array of 32 structs for maximum cache locality
    var stats: SIMD[DType.int64, 128] # 4 * 64-bit ints = 32 bytes per station. 32 * 32 = 1024 bytes
    # Wait, Mojo lists or a Tuple is easier. Or simply `List[StationStats]`
    var entries: List[StationStats]
    var occupied: List[Bool]
    var size: Int
    
    # We also keep lengths and ptrs strictly for printing out at the end, not used for lookups
    var ptrs: List[UnsafePointer[UInt8, MutExternalOrigin]]
    var lengths: List[Int]

    fn __init__(out self):
        self.entries = List[StationStats](capacity=Self.CAPACITY)
        self.occupied = List[Bool](capacity=Self.CAPACITY)
        self.ptrs = List[UnsafePointer[UInt8, MutExternalOrigin]](capacity=Self.CAPACITY)
        self.lengths = List[Int](capacity=Self.CAPACITY)
        self.size = 0
        
        for _ in range(Self.CAPACITY):
            self.entries.append(StationStats(0))
            self.entries[-1].count = 0 # manually zero out count
            self.occupied.append(False)
            self.ptrs.append(UnsafePointer[UInt8, MutExternalOrigin]())
            self.lengths.append(0)

    fn __copyinit__(out self, copy: Self):
        self.entries = copy.entries.copy()
        self.occupied = copy.occupied.copy()
        self.ptrs = copy.ptrs.copy()
        self.lengths = copy.lengths.copy()
        self.size = copy.size

    fn __moveinit__(out self, deinit take: Self):
        self.entries = take.entries^
        self.occupied = take.occupied^
        self.ptrs = take.ptrs^
        self.lengths = take.lengths^
        self.size = take.size

    @always_inline
    fn update_or_insert(
        mut self,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
        temp: Int,
    ):
        # Hash property: length + (first_byte << 8) + (last_byte << 16)
        var first = UInt64(ptr[0])
        var last = UInt64(ptr[length - 1])
        var k = UInt64(length) + (first << 8) + (last << 16)
        
        comptime MULTIPLIER: UInt64 = {m}
        comptime SHIFT: UInt64 = {shift}
        
        # O(1) perfect hash index, no loops, no string compares!
        var idx = Int((k * MULTIPLIER) >> SHIFT)
        
        var entries_ptr = self.entries.unsafe_ptr()
        if entries_ptr[idx].count > 0:
            entries_ptr[idx].update(temp)
        else:
            entries_ptr[idx] = StationStats(temp)
            
            var occ_ptr = self.occupied.unsafe_ptr()
            occ_ptr[idx] = True
            
            var ptrs_ptr = self.ptrs.unsafe_ptr()
            ptrs_ptr[idx] = ptr
            
            var str_len_ptr = self.lengths.unsafe_ptr()
            str_len_ptr[idx] = length
            
            self.size += 1

    fn update_from_stats(
        mut self,
        ptr: UnsafePointer[UInt8, MutExternalOrigin],
        length: Int,
        incoming: StationStats,
    ):
        var first = UInt64(ptr[0])
        var last = UInt64(ptr[length - 1])
        var k = UInt64(length) + (first << 8) + (last << 16)
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
    print("Wrote perfect_hashmap.mojo")
