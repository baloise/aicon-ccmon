#!/bin/bash
# Claude Code status line: model, context usage bar, 5h/7d rate limits.
# Installed by ccmon to ~/.claude/ccmon/statusline.sh

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

RESET="\033[0m"
DIM="\033[2m"
CYAN="\033[2;36m"
GREEN="\033[2;32m"
YELLOW="\033[2;33m"
RED="\033[2;31m"
GRAY="\033[2;37m"

segments=()

# Model name
segments+=("${CYAN}${model}${RESET}")

# Context window usage progress bar (10 segments)
if [ -n "$used_pct" ]; then
  filled=$(awk -v p="$used_pct" 'BEGIN{f=int((p+5)/10); if (f>10) f=10; if (f<0) f=0; print f}')
  empty=$((10 - filled))
  bar=""
  for ((i = 0; i < filled; i++)); do bar="${bar}#"; done
  for ((i = 0; i < empty; i++)); do bar="${bar}-"; done

  level=$(awk -v p="$used_pct" 'BEGIN{ if (p >= 80) print "red"; else if (p >= 50) print "yellow"; else print "green" }')
  case "$level" in
    red) color=$RED ;;
    yellow) color=$YELLOW ;;
    *) color=$GREEN ;;
  esac

  pct=$(awk -v p="$used_pct" 'BEGIN{printf "%.0f", p}')
  segments+=("${color}[${bar}] ${pct}%${RESET}")
fi

# 5h / 7d rate limit usage
rl=""
if [ -n "$five" ]; then
  rl="5h:$(awk -v p="$five" 'BEGIN{printf "%.0f", p}')%"
fi
if [ -n "$week" ]; then
  w="7d:$(awk -v p="$week" 'BEGIN{printf "%.0f", p}')%"
  if [ -n "$rl" ]; then
    rl="$rl $w"
  else
    rl="$w"
  fi
fi
if [ -n "$rl" ]; then
  segments+=("${GRAY}${rl}${RESET}")
fi

out=""
for s in "${segments[@]}"; do
  if [ -z "$out" ]; then
    out="$s"
  else
    out="${out} ${DIM}|${RESET} ${s}"
  fi
done

printf "%b\n" "$out"
