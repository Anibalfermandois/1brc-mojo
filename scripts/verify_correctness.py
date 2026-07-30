#!/usr/bin/env python3
"""Verify mmap and streaming results against a deterministic Python oracle."""

from __future__ import annotations

import math
import subprocess
import sys
import tempfile
from pathlib import Path


def build_fixture(stations_path: Path, output_path: Path) -> dict[str, tuple[int, int, int, int]]:
    stations = [
        line.strip()
        for line in stations_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    expected: dict[str, tuple[int, int, int, int]] = {}

    with output_path.open("w", encoding="utf-8", newline="\n") as handle:
        # Large enough that each worker crosses the stream's 4 MiB buffer
        # boundary on the usual 8-core target.
        for repetition in range(6_000):
            for index, station in enumerate(stations):
                # Cover one-, two-, and three-digit magnitudes and both signs.
                temperature = ((index * 73 + repetition * 191) % 1999) - 999
                handle.write(f"{station};{temperature / 10:.1f}\n")

                if station not in expected:
                    expected[station] = (temperature, temperature, temperature, 1)
                else:
                    minimum, maximum, total, count = expected[station]
                    expected[station] = (
                        min(minimum, temperature),
                        max(maximum, temperature),
                        total + temperature,
                        count + 1,
                    )

    return expected


def result_line(stdout: str) -> str:
    lines = [
        line
        for line in stdout.splitlines()
        if line.startswith("{") and line.endswith("}")
    ]
    if len(lines) != 1:
        raise AssertionError(f"expected one result map, found {len(lines)}")
    return lines[0][1:-1]


def parse_result(
    body: str, station_names: list[str]
) -> dict[str, tuple[float, float, float]]:
    parsed: dict[str, tuple[float, float, float]] = {}
    cursor = 0

    for index, station in enumerate(station_names):
        prefix = f"{station}="
        if not body.startswith(prefix, cursor):
            raise AssertionError(
                f"expected {prefix!r} at output offset {cursor}"
            )
        value_start = cursor + len(prefix)
        if index + 1 < len(station_names):
            delimiter = f", {station_names[index + 1]}="
            value_end = body.index(delimiter, value_start)
            cursor = value_end + 2
        else:
            value_end = len(body)
            cursor = value_end

        values = tuple(float(value) for value in body[value_start:value_end].split("/"))
        if len(values) != 3:
            raise AssertionError(f"invalid result tuple for {station}")
        parsed[station] = values

    if cursor != len(body):
        raise AssertionError("unexpected trailing result output")
    return parsed


def verify_mode(
    binary: Path,
    fixture: Path,
    expected: dict[str, tuple[int, int, int, int]],
    *extra_args: str,
) -> None:
    completed = subprocess.run(
        [str(binary), str(fixture), "--once", *extra_args],
        check=True,
        capture_output=True,
        text=True,
    )
    stations = sorted(expected)
    actual = parse_result(result_line(completed.stdout), stations)

    for station in stations:
        minimum, maximum, total, count = expected[station]
        expected_values = (minimum / 10, total / count / 10, maximum / 10)
        for observed, wanted in zip(actual[station], expected_values, strict=True):
            if not math.isclose(observed, wanted, rel_tol=1e-12, abs_tol=1e-12):
                raise AssertionError(
                    f"{station}: observed {actual[station]}, expected {expected_values}"
                )


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    binary = root / "bin" / "perf_bin"
    if not binary.is_file():
        print("ERROR: bin/perf_bin does not exist; run entrypoints/build.sh.", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="1brc-correctness-") as temp_dir:
        fixture = Path(temp_dir) / "measurements_correctness.txt"
        expected = build_fixture(root / "docs" / "stations413.txt", fixture)
        verify_mode(binary, fixture, expected)
        verify_mode(binary, fixture, expected, "--force-streaming")

    print(
        f"Correctness passed: {len(expected)} stations, "
        "mmap and forced streaming match the Python oracle."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
