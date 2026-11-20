#!/usr/bin/env python3
"""fourlines.py — compact CPU/GPU status for tmux status-right.

Python port of fourlines.sh. It prints the same single line:

    CPU:[<blocks>] GPU:[LOAD:<chart>|MEM:<chart>|TEMP:<chart>]

CPU: one horizontal line per SMT thread, grouped into blocks of four lines.
Each block is FOUR_LINES_CPU_WIDTH characters wide (default 2 => 4 levels per
thread). Blocks are separated with "|".

GPU: each braille character is 4 dots tall and 2 dots wide. The 4 dot rows are
mapped to the 4 AMD GPUs (card0..card3); the horizontal axis is the metric
value from 0 to 100%. All values come from sysfs, so no root is needed.

Tunables (environment variables):
  FOUR_LINES_WIDTH          GPU chart width in characters (default 6 => 12 levels)
  FOUR_LINES_CPU            set to 0 to hide the CPU chart (default 1)
  FOUR_LINES_CPU_WIDTH      CPU block width in characters (default 2 => 4 levels)
  FOUR_LINES_CPU_SAMPLE_MS  CPU sampling window in milliseconds (default 200)
  FOUR_LINES_TEMP_MIN       temperature mapped to an empty bar (default 30 C)
  FOUR_LINES_TEMP_MAX       temperature mapped to a full bar   (default 100 C)
  FOUR_LINES_TEMP_SENSOR    hwmon file to use: temp1=edge (default),
                            temp2=junction, temp3=HBM
  FOUR_LINES_DEBUG          set to 1 to dump raw GPU values to stderr

The script is intentionally stdlib-only; it reads /proc and sysfs directly
instead of shelling out to awk, cat, cut, basename, or sort.
"""

from __future__ import annotations

import glob
import os
import re
import sys
import time
from dataclasses import dataclass
from typing import Sequence

# Braille dot masks for the 4 rows, left and right column of a character.
# Row 0: dot 1 / dot 4, row 1: dot 2 / dot 5,
# Row 2: dot 3 / dot 6, row 3: dot 7 / dot 8.
LEFT_DOTS = (1, 2, 4, 64)
RIGHT_DOTS = (8, 16, 32, 128)

_UINT_RE = re.compile(r"[0-9]+")
_SINT_RE = re.compile(r"-?[0-9]+")
_CPU_LINE_RE = re.compile(r"^cpu[0-9]+\s")
_CPU_NAME_RE = re.compile(r"(.*?)([0-9]+)$")


@dataclass(frozen=True)
class Config:
    width: int = 6
    cpu_enabled: bool = True
    cpu_width: int = 2
    cpu_sample_ms: int = 200
    temp_min: int = 30
    temp_max: int = 100
    temp_sensor: str = "temp1_input"
    debug: bool = False

    @classmethod
    def from_env(cls) -> "Config":
        temp_min = _signed_env("FOUR_LINES_TEMP_MIN", 30)
        temp_max = _signed_env("FOUR_LINES_TEMP_MAX", 100)
        if temp_max <= temp_min:
            temp_min, temp_max = 30, 100

        return cls(
            width=_unsigned_env("FOUR_LINES_WIDTH", 6, minimum=1),
            cpu_enabled=(os.environ.get("FOUR_LINES_CPU") or "1") != "0",
            cpu_width=_unsigned_env("FOUR_LINES_CPU_WIDTH", 2, minimum=1),
            cpu_sample_ms=_unsigned_env("FOUR_LINES_CPU_SAMPLE_MS", 200, minimum=20),
            temp_min=temp_min,
            temp_max=temp_max,
            temp_sensor=os.environ.get("FOUR_LINES_TEMP_SENSOR") or "temp1_input",
            debug=(os.environ.get("FOUR_LINES_DEBUG") or "0") == "1",
        )


@dataclass(frozen=True)
class GpuSnapshot:
    load_levels: tuple[int, ...]
    mem_levels: tuple[int, ...]
    temp_levels: tuple[int, ...]
    debug_lines: tuple[str, ...]


def _unsigned_env(name: str, default: int, minimum: int) -> int:
    raw = os.environ.get(name)
    if not raw or _UINT_RE.fullmatch(raw) is None:
        return default
    value = int(raw)
    return value if value >= minimum else default


def _signed_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if not raw or _SINT_RE.fullmatch(raw) is None:
        return default
    return int(raw)


def _trunc_div(numerator: int, denominator: int) -> int:
    """Integer division truncated toward zero, like bash arithmetic."""
    if numerator >= 0:
        return numerator // denominator
    return -((-numerator) // denominator)


def chart(width: int, levels: Sequence[int]) -> str:
    """Build a horizontal bar chart.

    Arguments are the width in characters, then one 0..(width*2) level per dot
    row. Missing levels are treated as 0.
    """
    chars: list[str] = []
    for column in range(width):
        code = 0
        for row in range(4):
            level = levels[row] if row < len(levels) else 0
            # Global dot column for this character's left/right half.
            if column * 2 < level:
                code |= LEFT_DOTS[row]
            if column * 2 + 1 < level:
                code |= RIGHT_DOTS[row]
        # Braille occupies U+2800..U+28FF.
        chars.append(chr(0x2800 + code))
    return "".join(chars)


def chart_blocks(width: int, levels: Sequence[int]) -> str:
    """Build a chart for more than four rows, joining blocks with "|"."""
    return "|".join(
        chart(width, levels[start : start + 4])
        for start in range(0, len(levels), 4)
    )


def read_cpu_counters(path: str = "/proc/stat") -> dict[str, tuple[int, ...]]:
    """Read per-CPU cumulative counters from /proc/stat.

    Guest/guest_nice are already included in user/nice, so only the first
    eight numeric fields are needed.
    """
    counters: dict[str, tuple[int, ...]] = {}
    try:
        with open(path, encoding="ascii", errors="replace") as handle:
            for line in handle:
                if not _CPU_LINE_RE.match(line):
                    continue
                fields = line.split()
                if len(fields) < 9:
                    continue
                try:
                    values = tuple(int(value) for value in fields[1:9])
                except ValueError:
                    continue
                counters[fields[0]] = values
    except OSError:
        pass
    return counters


def _cpu_sort_key(name: str) -> tuple[str, int]:
    """Natural sort key, equivalent to `sort -V` for cpuN names."""
    match = _CPU_NAME_RE.fullmatch(name)
    if match is None:
        return name, -1
    return match.group(1), int(match.group(2))


def collect_cpu_levels(cpu_width: int, sample_ms: int) -> list[int]:
    """Compute one 0..(cpu_width*2) level per SMT thread.

    /proc/stat contains cumulative counters, so take two snapshots separated by
    sample_ms.
    """
    previous = read_cpu_counters()
    if not previous:
        return []

    time.sleep(sample_ms / 1000.0)
    current = read_cpu_counters()

    cpu_dots = cpu_width * 2
    levels: list[int] = []
    for name in sorted(current, key=_cpu_sort_key):
        if name not in previous:
            continue

        prev = previous[name]
        curr = current[name]
        # user, nice, system, irq, softirq, steal
        busy = (
            (curr[0] - prev[0])
            + (curr[1] - prev[1])
            + (curr[2] - prev[2])
            + (curr[5] - prev[5])
            + (curr[6] - prev[6])
            + (curr[7] - prev[7])
        )
        # idle, iowait
        idle = (curr[3] - prev[3]) + (curr[4] - prev[4])
        total = busy + idle

        # A counter reset (reboot, CPU hotplug) would produce nonsense; skip it.
        if busy < 0:
            busy = 0
        if total < 1:
            total = 1

        level = _trunc_div(busy * cpu_dots + total // 2, total)
        levels.append(max(0, min(cpu_dots, level)))

    return levels


def _read_int(path: str, default: int = 0) -> int:
    try:
        with open(path, encoding="ascii", errors="replace") as handle:
            return int(handle.read().strip())
    except (OSError, ValueError):
        return default


def _hwmon_path(device: str) -> str:
    """Return the first hwmon directory, or a literal path that will fail."""
    matches = sorted(glob.glob(os.path.join(device, "hwmon", "hwmon*")))
    if matches:
        return matches[0]
    return os.path.join(device, "hwmon", "hwmon*")


def collect_gpu_levels(config: Config) -> GpuSnapshot:
    load_levels: list[int] = []
    mem_levels: list[int] = []
    temp_levels: list[int] = []
    debug_lines: list[str] = []
    dots = config.width * 2

    for device in sorted(glob.glob("/sys/class/drm/card[0-9]*/device")):
        if not os.path.isfile(os.path.join(device, "gpu_busy_percent")):
            continue

        card = os.path.basename(os.path.dirname(device))
        hwmon = _hwmon_path(device)

        busy = _read_int(os.path.join(device, "gpu_busy_percent"))
        vram_used = _read_int(os.path.join(device, "mem_info_vram_used"))
        vram_total = _read_int(os.path.join(device, "mem_info_vram_total"))
        temp_raw = _read_int(os.path.join(hwmon, config.temp_sensor))
        temp = _trunc_div(temp_raw, 1000)

        if vram_total > 0:
            mempct = _trunc_div(vram_used * 100, vram_total)
        else:
            mempct = 0

        # Round each metric onto the 0..dots bar length.
        load_level = _trunc_div(busy * dots + 50, 100)
        mem_level = _trunc_div(mempct * dots + 50, 100)

        if temp <= config.temp_min:
            temp_level = 0
        elif temp >= config.temp_max:
            temp_level = dots
        else:
            span = config.temp_max - config.temp_min
            temp_level = _trunc_div(
                (temp - config.temp_min) * dots + span // 2, span
            )

        # Keep values inside the chart even if sysfs reports something odd.
        load_level = max(0, min(dots, load_level))
        mem_level = max(0, min(dots, mem_level))
        temp_level = max(0, min(dots, temp_level))

        load_levels.append(load_level)
        mem_levels.append(mem_level)
        temp_levels.append(temp_level)
        debug_lines.append(f"{card} load={busy}% mem={mempct}% temp={temp}C")

        # Braille charts are only 4 dot rows tall.
        if len(load_levels) >= 4:
            break

    return GpuSnapshot(
        load_levels=tuple(load_levels),
        mem_levels=tuple(mem_levels),
        temp_levels=tuple(temp_levels),
        debug_lines=tuple(debug_lines),
    )


def render(config: Config, cpu_levels: Sequence[int], gpu: GpuSnapshot) -> str:
    segments: list[str] = []

    if cpu_levels:
        segments.append(f"CPU:[{chart_blocks(config.cpu_width, cpu_levels)}]")

    gpu_segments = (
        f"LOAD:{chart(config.width, gpu.load_levels)}",
        f"MEM:{chart(config.width, gpu.mem_levels)}",
        f"TEMP:{chart(config.width, gpu.temp_levels)}",
    )
    segments.append("GPU:[" + "|".join(gpu_segments) + "]")

    return " ".join(segments)


def main() -> int:
    config = Config.from_env()
    gpu = collect_gpu_levels(config)

    if config.debug and gpu.debug_lines:
        for line in gpu.debug_lines:
            print(line, file=sys.stderr)

    if config.cpu_enabled:
        cpu_levels = collect_cpu_levels(config.cpu_width, config.cpu_sample_ms)
    else:
        cpu_levels = []

    line = render(config, cpu_levels, gpu)
    # Emit UTF-8 directly so the output does not depend on the locale.
    sys.stdout.buffer.write(line.encode("utf-8") + b"\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
