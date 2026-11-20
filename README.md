# fourlines

Compact CPU/GPU status for the 4-GPU Mac Pro, designed for `tmux status-right`.

`fourlines.sh` prints one line with two bracketed groups:

```
CPU:[<blocks>] GPU:[LOAD:<chart>|MEM:<chart>|TEMP:<chart>]
```

## CPU

One narrow horizontal line per SMT thread (32 on this machine), grouped into
blocks of four lines. Each block is 2 characters wide by default, giving 4
levels per thread; blocks are separated with `|`:

```
CPU:[⣿⣿|⡇ |⡗⠒|⡗]
```

The 16-core / 32-thread Xeon is sampled twice from `/proc/stat` over a short
window (200 ms by default), so no state file is needed.

## GPU

Each braille character is 4 dots tall and 2 dots wide. The 4 dot rows map
naturally to the 4 AMD GPUs (`card0`..`card3`), and the horizontal axis is the
metric value from 0 to 100% — so each chart is four horizontal bars.

```
CPU:[⠛⠛|⠒⠒|⠀⠀|⠀⠀|⠀⠀|⠛⠛|⠀⠀|⣀⣀] GPU:[LOAD:⣶⣶⣶⣶⣶⡤|MEM:⣿⣿⣿⣿⣿⣿|TEMP:⣿⠋⠀⠀⠀⠀]
```

Metrics (all read from sysfs, no root needed):

| Chart | Source |
|-------|--------|
| LOAD  | `gpu_busy_percent` |
| MEM   | `mem_info_vram_used / mem_info_vram_total` |
| TEMP  | `hwmon/temp1_input` (edge sensor by default) |

## Usage

```sh
./fourlines.sh
```

Add it to `~/.tmux.conf`:

```tmux
set -g status-right '#(/path/to/fourlines/fourlines.sh)'
# or with something else on the right:
set -g status-right '#(/path/to/fourlines/fourlines.sh) %H:%M'
```

## Python version

`fourlines.py` is a stdlib-only Python 3.10+ port of `fourlines.sh` with the
same output, tunables, and defaults. It reads `/proc` and sysfs directly and
avoids spawning helper processes.

```sh
./fourlines.py
```

Use it in tmux the same way:

```tmux
set -g status-right '#(/path/to/fourlines/fourlines.py)'
```

No third-party packages are required.

## Tunables

| Variable | Default | Meaning |
|----------|---------|---------|
| `FOUR_LINES_WIDTH` | `6` | GPU chart width in characters (2 dots per character) |
| `FOUR_LINES_CPU` | `1` | Set to `0` to hide the CPU chart |
| `FOUR_LINES_CPU_WIDTH` | `2` | CPU block width in characters (2 dots per character) |
| `FOUR_LINES_CPU_SAMPLE_MS` | `200` | CPU sampling window in milliseconds |
| `FOUR_LINES_TEMP_MIN` | `30` | Temperature mapped to an empty bar |
| `FOUR_LINES_TEMP_MAX` | `100` | Temperature mapped to a full bar |
| `FOUR_LINES_TEMP_SENSOR` | `temp1_input` | `temp1_input` = edge, `temp2_input` = junction, `temp3_input` = HBM |
| `FOUR_LINES_DEBUG` | `0` | Set to `1` to dump raw per-GPU values to stderr |

## Reference files

- `gpustat_v2.sh` — full per-card/fan status table for the same machine.
- `metrics_monitor_braille.swift` — original compact braille monitor for
  Apple Silicon.
