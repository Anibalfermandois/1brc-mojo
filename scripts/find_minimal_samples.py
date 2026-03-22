"""
Find the minimal set of byte positions that uniquely identify all 413 stations.
Tests all combinations of sample positions to find which ones work with 4 or 3 loads.
"""

from itertools import combinations

def load_stations(filename):
    with open(filename, 'r') as f:
        return [line.strip() for line in f if line.strip()]

# Position functions: given a name's bytes and length, return the byte at that position
# Each is (name, function, description)
POSITIONS = [
    ("b[0]",      lambda b, L: b[0]),
    ("b[1]",      lambda b, L: b[1] if L > 1 else 0),
    ("b[2]",      lambda b, L: b[2] if L > 2 else 0),
    ("b[3]",      lambda b, L: b[3] if L > 3 else 0),
    ("b[L//2]",   lambda b, L: b[L // 2]),
    ("b[L//3]",   lambda b, L: b[L // 3] if L >= 3 else 0),
    ("b[L//4]",   lambda b, L: b[L // 4] if L >= 4 else 0),
    ("b[L*3//4]", lambda b, L: b[L * 3 // 4] if L >= 4 else 0),
    ("b[L*2//3]", lambda b, L: b[L * 2 // 3] if L >= 3 else 0),
    ("b[-1]",     lambda b, L: b[L - 1]),
    ("b[-2]",     lambda b, L: b[L - 2] if L > 1 else 0),
    ("b[-3]",     lambda b, L: b[L - 3] if L > 2 else 0),
]

def test_combination(stations_bytes, position_indices):
    """Check if a combination of positions + length uniquely identifies all stations."""
    keys = set()
    for b, L in stations_bytes:
        # Build key: length in lowest byte, then each position in successive bytes
        key = L
        for shift, pi in enumerate(position_indices, 1):
            _, fn = POSITIONS[pi]
            key |= fn(b, L) << (8 * shift)
        if key in keys:
            return False
        keys.add(key)
    return True

def find_collisions(stations, stations_bytes, position_indices):
    """Find which stations collide for a given combination."""
    keys = {}
    collisions = []
    for i, (b, L) in enumerate(stations_bytes):
        key = L
        for shift, pi in enumerate(position_indices, 1):
            _, fn = POSITIONS[pi]
            key |= fn(b, L) << (8 * shift)
        if key in keys:
            collisions.append((stations[keys[key]], stations[i]))
        else:
            keys[key] = i
    return collisions

if __name__ == '__main__':
    stations = load_stations('docs/stations413.txt')
    stations_bytes = [(s.encode('utf-8'), len(s.encode('utf-8'))) for s in stations]

    print(f"Testing {len(stations)} stations with {len(POSITIONS)} sample positions")
    print(f"Positions: {[p[0] for p in POSITIONS]}\n")

    # Test 3-load combinations
    print("=" * 60)
    print("3-LOAD COMBINATIONS (length + 3 bytes)")
    print("=" * 60)
    found_3 = []
    for combo in combinations(range(len(POSITIONS)), 3):
        if test_combination(stations_bytes, combo):
            names = [POSITIONS[i][0] for i in combo]
            found_3.append((combo, names))
            print(f"  UNIQUE: {names}")
    if not found_3:
        print("  None found.")
    print(f"\n  Total 3-load combinations that work: {len(found_3)}")

    # Test 4-load combinations
    print("\n" + "=" * 60)
    print("4-LOAD COMBINATIONS (length + 4 bytes)")
    print("=" * 60)
    found_4 = []
    for combo in combinations(range(len(POSITIONS)), 4):
        if test_combination(stations_bytes, combo):
            names = [POSITIONS[i][0] for i in combo]
            found_4.append((combo, names))

    if found_4:
        # Only print first 20 to avoid spam
        for combo, names in found_4[:20]:
            print(f"  UNIQUE: {names}")
        if len(found_4) > 20:
            print(f"  ... and {len(found_4) - 20} more")
    else:
        print("  None found.")
    print(f"\n  Total 4-load combinations that work: {len(found_4)}")

    # Show collisions for the closest 3-load misses
    if not found_3:
        print("\n" + "=" * 60)
        print("CLOSEST 3-LOAD MISSES (fewest collisions)")
        print("=" * 60)
        results = []
        for combo in combinations(range(len(POSITIONS)), 3):
            collisions = find_collisions(stations, stations_bytes, combo)
            names = [POSITIONS[i][0] for i in combo]
            results.append((len(collisions), names, collisions))
        results.sort()
        for n_coll, names, colls in results[:10]:
            print(f"  {n_coll} collision(s): {names}")
            for a, b in colls[:3]:
                print(f"      '{a}' <-> '{b}'")
