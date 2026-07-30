#!/usr/bin/env python3
"""Summarize raw 1BRC benchmark samples without discarding noisy runs."""

from __future__ import annotations

import csv
import statistics
import sys
from pathlib import Path


def summarize(values: list[float]) -> tuple[float, float, float, float, float]:
    median = statistics.median(values)
    mad = statistics.median(abs(value - median) for value in values)
    q1, _, q3 = statistics.quantiles(values, n=4, method="inclusive")
    return median, mad, q3 - q1, min(values), max(values)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: summarize_benchmark.py RESULTS.csv", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    if len(rows) < 5:
        print("ERROR: at least five samples are required.", file=sys.stderr)
        return 1

    wall = [float(row["wall_ms"]) for row in rows]
    parse = [float(row["parse_ms"]) for row in rows]

    print("# Benchmark summary")
    print()
    print(f"- Samples: {len(rows)}")
    print("- Condition: normal concurrent machine use; no samples discarded")
    print("- Primary promotion metric: end-to-end wall clock")
    print()
    print("| Metric | Median | MAD | IQR | Min | Max | Relative MAD |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for label, values in (("Wall clock", wall), ("Internal parse", parse)):
        median, mad, iqr, minimum, maximum = summarize(values)
        relative_mad = mad / median * 100 if median else 0.0
        print(
            f"| {label} | {median:.3f} ms | {mad:.3f} ms | "
            f"{iqr:.3f} ms | {minimum:.3f} ms | {maximum:.3f} ms | "
            f"{relative_mad:.2f}% |"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
