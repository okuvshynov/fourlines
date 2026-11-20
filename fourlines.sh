#!/usr/bin/env bash
# fourlines.sh — compact CPU/GPU status for tmux status-right.
#
# Prints one line with a narrow per-thread CPU chart followed by three GPU
# braille bar charts:
#
#   CPU:<blocks>|LOAD:<chart>|MEM:<chart>|TEMP:<chart>
#
# CPU: one horizontal line per SMT thread, grouped into blocks of four lines.
# Each block is FOUR_LINES_CPU_WIDTH characters wide (default 2 => 4 levels
# per thread). Blocks are separated with "|", e.g.
#
#   CPU:⣿⣿|⡇ |⡗⠒|⡗
#
# GPU: each braille character is 4 dots tall and 2 dots wide. The 4 dot rows
# are mapped to the 4 AMD GPUs (card0..card3); the horizontal axis is the
# metric value from 0 to 100%. No root is needed: all values come from sysfs,
# the same files gpustat_v2.sh / rocm-smi read.
#
# Tunables (environment variables):
#   FOUR_LINES_WIDTH        GPU chart width in characters (default 6 => 12 levels)
#   FOUR_LINES_CPU          set to 0 to hide the CPU chart (default 1)
#   FOUR_LINES_CPU_WIDTH    CPU block width in characters (default 2 => 4 levels)
#   FOUR_LINES_CPU_SAMPLE_MS  CPU sampling window in milliseconds (default 200)
#   FOUR_LINES_TEMP_MIN     temperature mapped to an empty bar (default 30 °C)
#   FOUR_LINES_TEMP_MAX     temperature mapped to a full bar   (default 100 °C)
#   FOUR_LINES_TEMP_SENSOR  hwmon file to use: temp1=edge (default),
#                           temp2=junction, temp3=HBM
#   FOUR_LINES_DEBUG        set to 1 to dump raw GPU values to stderr

set -euo pipefail

WIDTH=${FOUR_LINES_WIDTH:-6}
CPU_ENABLED=${FOUR_LINES_CPU:-1}
CPU_WIDTH=${FOUR_LINES_CPU_WIDTH:-2}
CPU_SAMPLE_MS=${FOUR_LINES_CPU_SAMPLE_MS:-200}
TEMP_MIN=${FOUR_LINES_TEMP_MIN:-30}
TEMP_MAX=${FOUR_LINES_TEMP_MAX:-100}
TEMP_SENSOR=${FOUR_LINES_TEMP_SENSOR:-temp1_input}

# Sanity-check the tunables so bad env values cannot break the arithmetic.
if ! [[ $WIDTH =~ ^[0-9]+$ ]] || ((WIDTH < 1)); then
  WIDTH=6
fi
if ! [[ $CPU_WIDTH =~ ^[0-9]+$ ]] || ((CPU_WIDTH < 1)); then
  CPU_WIDTH=2
fi
if ! [[ $CPU_SAMPLE_MS =~ ^[0-9]+$ ]] || ((CPU_SAMPLE_MS < 20)); then
  CPU_SAMPLE_MS=200
fi
if ! [[ $TEMP_MIN =~ ^-?[0-9]+$ ]] || ! [[ $TEMP_MAX =~ ^-?[0-9]+$ ]] || ((TEMP_MAX <= TEMP_MIN)); then
  TEMP_MIN=30
  TEMP_MAX=100
fi

DOTS=$((WIDTH * 2))

# Braille dot masks for the 4 rows, left and right column of a character.
# Row 0: dot 1 / dot 4, row 1: dot 2 / dot 5,
# Row 2: dot 3 / dot 6, row 3: dot 7 / dot 8.
LEFT_DOTS=(1 2 4 64)
RIGHT_DOTS=(8 16 32 128)

# Build a horizontal bar chart. Arguments: width, then one 0..(width*2) level
# per dot row. Missing levels are treated as 0.
chart() {
  local width=$1
  shift
  local -a levels=("$@")
  local out="" p j code level b2 b3 h2 h3

  for ((p = 0; p < width; p++)); do
    code=0
    for ((j = 0; j < 4; j++)); do
      level=${levels[j]:-0}
      # Global dot column for this character's left/right half.
      if ((p * 2 < level)); then
        code=$((code | LEFT_DOTS[j]))
      fi
      if ((p * 2 + 1 < level)); then
        code=$((code | RIGHT_DOTS[j]))
      fi
    done
    # Braille occupies U+2800..U+28FF. Emit the three UTF-8 bytes directly so
    # the output does not depend on the locale (bash printf \U is disabled
    # under LC_ALL=C).
    b2=$((0xA0 | (code >> 6)))
    b3=$((0x80 | (code & 0x3F)))
    printf -v h2 '%02x' "$b2"
    printf -v h3 '%02x' "$b3"
    printf -v ch "\\xE2\\x$h2\\x$h3"
    out+=$ch
  done
  printf '%s' "$out"
}

# Build a chart for more than four rows by splitting the levels into groups of
# four and joining the resulting braille blocks with "|".
chart_blocks() {
  local width=$1
  shift
  local -a levels=("$@")
  local out="" i

  for ((i = 0; i < ${#levels[@]}; i += 4)); do
    ((i > 0)) && out+='|'
    out+=$(chart "$width" "${levels[@]:i:4}")
  done
  printf '%s' "$out"
}

# Per-CPU cumulative counters from /proc/stat. Guest/guest_nice are already
# included in user/nice, so only the first eight numeric fields are needed.
read_cpu_counters() {
  awk '/^cpu[0-9]+[[:space:]]/ {
    printf "%s %s %s %s %s %s %s %s %s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9
  }' /proc/stat 2>/dev/null
}

# Compute one 0..(CPU_WIDTH*2) level per SMT thread. /proc/stat contains
# cumulative counters, so take two snapshots separated by CPU_SAMPLE_MS.
collect_cpu_levels() {
  local -a result=()
  local -A prev=()
  local -A busy_by_cpu=()
  local -A total_by_cpu=()
  local name u n s i w irq sirq st
  local pu pn ps pi pw pirq psirq pst
  local busy idle total level
  local cpu_dots=$((CPU_WIDTH * 2))
  local sleep_s

  while read -r name u n s i w irq sirq st; do
    prev["$name"]="$u $n $s $i $w $irq $sirq $st"
  done < <(read_cpu_counters)

  ((${#prev[@]} > 0)) || return 0

  printf -v sleep_s '%d.%03d' $((CPU_SAMPLE_MS / 1000)) $((CPU_SAMPLE_MS % 1000))
  sleep "$sleep_s"

  while read -r name u n s i w irq sirq st; do
    [ -n "${prev[$name]:-}" ] || continue
    read -r pu pn ps pi pw pirq psirq pst <<< "${prev[$name]}"

    busy=$(((u - pu) + (n - pn) + (s - ps) + (irq - pirq) + (sirq - psirq) + (st - pst)))
    idle=$(((i - pi) + (w - pw)))
    total=$((busy + idle))

    # A counter reset (reboot, CPU hotplug) would produce nonsense; skip it.
    ((busy < 0)) && busy=0
    ((total < 1)) && total=1

    busy_by_cpu["$name"]=$busy
    total_by_cpu["$name"]=$total
  done < <(read_cpu_counters)

  for name in $(printf '%s\n' "${!total_by_cpu[@]}" | sort -V); do
    busy=${busy_by_cpu[$name]}
    total=${total_by_cpu[$name]}
    level=$(((busy * cpu_dots + total / 2) / total))
    ((level < 0)) && level=0
    ((level > cpu_dots)) && level=$cpu_dots
    result+=("$level")
  done

  ((${#result[@]} > 0)) && printf '%s\n' "${result[@]}"
}

load_levels=()
mem_levels=()
temp_levels=()
debug=()

for D in /sys/class/drm/card[0-9]*/device; do
  [ -f "$D/gpu_busy_percent" ] || continue

  card=$(basename "$(dirname "$D")")
  H=$(echo "$D"/hwmon/hwmon* | cut -d' ' -f1)

  busy=$(cat "$D/gpu_busy_percent" 2>/dev/null || echo 0)
  vused=$(cat "$D/mem_info_vram_used" 2>/dev/null || echo 0)
  vtot=$(cat "$D/mem_info_vram_total" 2>/dev/null || echo 0)
  temp_raw=$(cat "$H/$TEMP_SENSOR" 2>/dev/null || echo 0)
  temp=$((temp_raw / 1000))

  if ((vtot > 0)); then
    mempct=$((vused * 100 / vtot))
  else
    mempct=0
  fi

  # Round each metric onto the 0..DOTS bar length.
  load_level=$(((busy * DOTS + 50) / 100))
  mem_level=$(((mempct * DOTS + 50) / 100))

  if ((temp <= TEMP_MIN)); then
    temp_level=0
  elif ((temp >= TEMP_MAX)); then
    temp_level=$DOTS
  else
    temp_level=$((((temp - TEMP_MIN) * DOTS + (TEMP_MAX - TEMP_MIN) / 2) / (TEMP_MAX - TEMP_MIN)))
  fi

  # Keep values inside the chart even if sysfs reports something odd.
  if ((load_level < 0)); then load_level=0; fi
  if ((load_level > DOTS)); then load_level=$DOTS; fi
  if ((mem_level < 0)); then mem_level=0; fi
  if ((mem_level > DOTS)); then mem_level=$DOTS; fi
  if ((temp_level < 0)); then temp_level=0; fi
  if ((temp_level > DOTS)); then temp_level=$DOTS; fi

  load_levels+=("$load_level")
  mem_levels+=("$mem_level")
  temp_levels+=("$temp_level")
  debug+=("$card load=${busy}% mem=${mempct}% temp=${temp}C")

  # Braille charts are only 4 dot rows tall.
  ((${#load_levels[@]} >= 4)) && break
done

if [ "${FOUR_LINES_DEBUG:-0}" = 1 ] && [ "${#debug[@]}" -gt 0 ]; then
  printf '%s\n' "${debug[@]}" >&2
fi

cpu_levels=()
if [ "$CPU_ENABLED" != 0 ]; then
  while IFS= read -r level; do
    [ -n "$level" ] && cpu_levels+=("$level")
  done < <(collect_cpu_levels)
fi

segments=()
if [ "${#cpu_levels[@]}" -gt 0 ]; then
  segments+=("CPU:$(chart_blocks "$CPU_WIDTH" "${cpu_levels[@]}")")
fi
segments+=("LOAD:$(chart "$WIDTH" "${load_levels[@]}")")
segments+=("MEM:$(chart "$WIDTH" "${mem_levels[@]}")")
segments+=("TEMP:$(chart "$WIDTH" "${temp_levels[@]}")")

printf '%s\n' "$(IFS='|'; printf '%s' "${segments[*]}")"
