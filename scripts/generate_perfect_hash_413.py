import sys
import random

def load_stations(filename):
    with open(filename, 'r') as f:
        return [line.strip() for line in f if line.strip()]

def string_to_int(s):
    b = s.encode('utf-8')
    val = 0
    for i in range(min(8, len(b))):
        val |= (b[i] << (8 * i))
    # Mix length into the upper bits
    val ^= (len(b) & 0xFF) << 56
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
    stations = load_stations('docs/stations413.txt')
    m, shift, size = find_perfect_hash(stations)
    
    print(f"MULTIPLIER: {m}")
    print(f"SHIFT: {shift}")
    print(f"CAPACITY: {size}")
    sys.exit(0)
