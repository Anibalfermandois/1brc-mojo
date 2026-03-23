from std.compile import compile_info
from engine.parser import parse_row, parse_chunk
from engine.perfect_hashmap import PerfectStationMap
from misc.metrics import EmptyParserMetrics, EmptyMapMetrics

fn main():
    comptime MAP_T = EmptyMapMetrics
    comptime PARSER_TRACKER_T = EmptyParserMetrics
    
    # parse_row
    comptime concrete_parse_row = parse_row[PARSER_TRACKER_T, MAP_T]
    print("=== parse_row (ASM) ===")
    print(compile_info[concrete_parse_row, emission_kind="asm"]().asm)
    print("\n=== parse_row (LLVM-OPT) ===")
    print(compile_info[concrete_parse_row, emission_kind="llvm-opt"]().asm)
    
    # parse_chunk
    comptime concrete_parse_chunk = parse_chunk[PARSER_TRACKER_T, MAP_T]
    print("\n=== parse_chunk (ASM) ===")
    print(compile_info[concrete_parse_chunk, emission_kind="asm"]().asm)
    print("\n=== parse_chunk (LLVM-OPT) ===")
    print(compile_info[concrete_parse_chunk, emission_kind="llvm-opt"]().asm)
    
    # PerfectStationMap.update_or_insert
    comptime concrete_map = PerfectStationMap[MAP_TRACKER=MAP_T]
    comptime concrete_update_or_insert = concrete_map.update_or_insert
    print("\n=== update_or_insert (ASM) ===")
    print(compile_info[concrete_update_or_insert, emission_kind="asm"]().asm)
    print("\n=== update_or_insert (LLVM-OPT) ===")
    print(compile_info[concrete_update_or_insert, emission_kind="llvm-opt"]().asm)
