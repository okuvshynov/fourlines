#!/usr/bin/env bash
# fourlines.sh — compact GPU status for tmux status-right.
#
# Prints one line with three braille bar charts:
#
#   LOAD:<chart>|MEM:<chart>|TEMP:<chart>
#
# Each braille character is 4 dots tall and 2 dots wide. The 4 dot rows are
# mapped to the 4 AMD GPUs (card0..card3); the horizontal axis is the metric
# value from 0 to 100%. No root is needed: all values come from sysfs, the
# same files gpustat_v2.sh / rocm-smi read.
#
# Tunables (environment variables):
#   FOUR_LINES_WIDTH       chart width in characters (default 6 => 12 levels)
#   FOUR_LINES_TEMP_MIN    temperature mapped to an empty bar (default 30 °C)
#   FOUR_LINES_TEMP_MAX    temperature mapped to a full bar   (default 100 °C)
#   FOUR_LINES_TEMP_SENSOR hwmon file to use: temp1=edge (default),
#                          temp2=junction, temp3=HBM
#   FOUR_LINES_DEBUG       set to 1 to dump raw GPU values to stderr

set -euo pipefail

WIDTH=${FOUR_LINES_WIDTH:-6}
TEMP_MIN=${FOUR_LINES_TEMP_MIN:-30}
TEMP_MAX=${FOUR_LINES_TEMP_MAX:-100}
TEMP_SENSOR=${FOUR_LINES_TEMP_SENSOR:-temp1_input}

# Sanity-check the tunables so bad env values cannot break the arithmetic.
if ! [[ $WIDTH =~ ^[0-9]+$ ]] || ((WIDTH < 1)); then
  WIDTH=6
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

# Build a horizontal bar chart. Arguments: width, then one 0..DOTS level per
# dot row (GPU). Missing levels are treated as 0.
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

printf 'LOAD:%s|MEM:%s|TEMP:%s\n' \
  "$(chart "$WIDTH" "${load_levels[@]}")" \
  "$(chart "$WIDTH" "${mem_levels[@]}")" \
  "$(chart "$WIDTH" "${temp_levels[@]}")"
