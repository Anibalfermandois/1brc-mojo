from std.time import perf_counter_ns
from std.collections import Dict


struct Profiler:
    var _starts: Dict[String, Int]
    var _totals: Dict[String, Int]
    var _order: List[String]
    var _total_start: Int

    fn __init__(out self):
        self._starts = Dict[String, Int]()
        self._totals = Dict[String, Int]()
        self._order = List[String]()
        self._total_start = Int(perf_counter_ns())

    fn tic(mut self, name: String):
        self._starts[name] = Int(perf_counter_ns())
        if name not in self._totals:
            self._totals[name] = 0
            self._order.append(name)

    fn toc(mut self, name: String):
        var end = Int(perf_counter_ns())
        try:
            if name in self._starts:
                var start = self._starts[name]
                self._totals[name] += end - start
        except:
            pass

    fn report(self) raises:
        var total_end = Int(perf_counter_ns())
        var wall_time_ns = total_end - self._total_start
        var wall_time_ms = Float64(wall_time_ns) / 1_000_000.0

        print("\n" + "=" * 60)
        print("PROFILER REPORT")
        print("=" * 60)

        for i in range(len(self._order)):
            var name = self._order[i]
            var total_ns = self._totals.get(name, 0)
            var total_ms = Float64(total_ns) / 1_000_000.0
            var pct = (Float64(total_ns) / Float64(wall_time_ns)) * 100.0

            print(
                "  ",
                self._pad_right(name, 25),
                "| ",
                self._pad_left(self._fmt_float(total_ms), 10),
                " ms (",
                self._fmt_float(pct),
                "%)",
            )

        print("-" * 60)
        print(
            "  Total Wall Time:           ",
            self._fmt_float(wall_time_ms),
            " ms",
        )
        print("=" * 60 + "\n")

    fn _pad_right(self, s: String, width: Int) -> String:
        var out = s
        while len(out) < width:
            out += " "
        return out

    fn _pad_left(self, s: String, width: Int) -> String:
        var out = s
        while len(out) < width:
            out = " " + out
        return out

    fn _fmt_float(self, v: Float64) -> String:
        var i = Int(v)
        var frac = Int((v - Float64(i)) * 100.0)
        if frac < 0:
            frac = -frac
        var frac_str = String(frac)
        if frac < 10:
            frac_str = "0" + frac_str
        return String(i) + "." + frac_str
