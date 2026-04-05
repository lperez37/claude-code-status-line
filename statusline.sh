#!/usr/bin/env bash
# Claude Code Status Line
# Two-line status bar with session info, cost tracking, and context usage.
# Reads JSON from stdin (provided by Claude Code's statusLine feature).

input=$(cat)

# ── Parse JSON ──────────────────────────────────────────────────────────────
cwd=$(echo "$input"          | jq -r '.workspace.current_dir // .cwd // ""')
model=$(echo "$input"        | jq -r '.model.display_name // ""')
used_pct=$(echo "$input"     | jq -r '.context_window.used_percentage // empty')
real_cost=$(echo "$input"    | jq -r '.cost.total_cost_usd // 0')
total_duration=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
lines_added=$(echo "$input"  | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input"| jq -r '.cost.total_lines_removed // 0')
vim_mode=$(echo "$input"     | jq -r '.vim.mode // ""')
session_name=$(echo "$input" | jq -r '.session_name // ""')

# Cost cache (updated by cost-tracker.sh on a timer)
COST_CACHE="$HOME/.claude/cost-cache.json"
if [ -f "$COST_CACHE" ]; then
  cost_today=$(jq -r '.today // 0' "$COST_CACHE")
  cost_week=$(jq -r '.week // 0' "$COST_CACHE")
  cost_month=$(jq -r '.month // 0' "$COST_CACHE")
else
  cost_today=0; cost_week=0; cost_month=0
fi

# ── ANSI Colors ─────────────────────────────────────────────────────────────
RST='\033[0m'; DIM='\033[2m'; BOLD='\033[1m'
CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'
BLUE='\033[34m'; MAGENTA='\033[35m'; WHITE='\033[37m'
PINK='\033[38;5;213m'
# 256-color for context bar gradient
C_LO='\033[38;5;34m'    # green
C_MID='\033[38;5;214m'  # orange
C_HI='\033[38;5;196m'   # red
C_EMPTY='\033[38;5;238m' # dark gray

# ── Helpers ─────────────────────────────────────────────────────────────────

short_path() {
  local p="${1/$HOME/\~}"
  local depth
  depth=$(echo "$p" | tr -cd '/' | wc -c)
  if [ "$depth" -gt 2 ]; then
    echo "…/$(echo "$p" | rev | cut -d'/' -f1-2 | rev)"
  else
    echo "$p"
  fi
}

context_bar() {
  local pct="${1:-0}"
  local width=10
  local filled=$(( pct * width / 100 ))
  local bar=""
  for i in $(seq 1 "$width"); do
    if [ "$i" -le "$filled" ]; then
      if [ "$pct" -lt 50 ]; then
        bar="${bar}${C_LO}█"
      elif [ "$pct" -lt 75 ]; then
        bar="${bar}${C_MID}█"
      else
        bar="${bar}${C_HI}█"
      fi
    else
      bar="${bar}${C_EMPTY}░"
    fi
  done
  echo "${bar}${RST}"
}

git_branch() {
  git -C "$1" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$1" --no-optional-locks rev-parse --short HEAD 2>/dev/null
}

cost_colour() {
  local cost="$1"
  awk -v c="$cost" -v g="$GREEN" -v y="$YELLOW" -v r="$RED" \
      'BEGIN {
        if (c + 0 < 5)       { printf "%s", g }
        else if (c + 0 < 15) { printf "%s", y }
        else                  { printf "%s", r }
      }'
}

fmt_cost() {
  local cost="$1"
  awk -v c="$cost" 'BEGIN {
    val = c + 0
    if (val < 0.01)      { printf "$%.4f", val }
    else if (val < 0.10) { printf "$%.3f", val }
    else                 { printf "$%.2f", val }
  }'
}

fmt_pink() {
  awk -v c="$1" 'BEGIN {
    if (c+0 >= 1000) printf "$%.1fk", c/1000
    else if (c+0 >= 1) printf "$%.0f", c
    else printf "$%.2f", c
  }'
}

# ── Build segments ──────────────────────────────────────────────────────────
line1=()
line2=()

# ── Line 1: location, session info, context ────────────────────────────────

# Directory
if [ -n "$cwd" ]; then
  dir_str=$(short_path "$cwd")
  line1+=("$(printf "${CYAN} %s${RST}" "$dir_str")")
fi

# Git branch
if [ -n "$cwd" ]; then
  branch=$(git_branch "$cwd")
  if [ -n "$branch" ]; then
    line1+=("$(printf "${MAGENTA}%s${RST}" "$branch")")
  fi
fi

# Model
if [ -n "$model" ]; then
  short_model="${model#Claude }"
  line1+=("$(printf "${BLUE}󰊠 %s${RST}" "$short_model")")
fi

# Lines changed
if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
  line1+=("$(printf "${GREEN}+%s${RST} ${RED}-%s${RST}" "$lines_added" "$lines_removed")")
fi

# Vim mode
if [ -n "$vim_mode" ] && [ "$vim_mode" != "null" ]; then
  if [ "$vim_mode" = "NORMAL" ]; then
    line1+=("$(printf "${YELLOW}[N]${RST}")")
  elif [ "$vim_mode" = "INSERT" ]; then
    line1+=("$(printf "${GREEN}[I]${RST}")")
  fi
fi

# Session name
if [ -n "$session_name" ] && [ "$session_name" != "null" ]; then
  line1+=("$(printf "${DIM}\"%s\"${RST}" "$session_name")")
fi

# Context bar (rightmost on line 1)
if [ -n "$used_pct" ] && [ "$used_pct" != "null" ]; then
  pct_int=$(printf '%.0f' "$used_pct")
  bar=$(context_bar "$pct_int")
  line1+=("$(printf "%b ${DIM}%s%%${RST}" "$bar" "$pct_int")")
fi

# ── Line 2: costs & duration ───────────────────────────────────────────────

# "true cost" label + color-coded session cost
cost_col=$(cost_colour "$real_cost")
cost_str=$(fmt_cost "$real_cost")
line2+=("$(printf "${DIM}true cost${RST} ${cost_col}%s${RST}" "$cost_str")")

# Aggregate costs (today / week / month) in pink
t_str=$(fmt_pink "$cost_today")
w_str=$(fmt_pink "$cost_week")
m_str=$(fmt_pink "$cost_month")
line2+=("$(printf "${DIM}today${RST} ${PINK}%s${RST} ${DIM}wk${RST} ${PINK}%s${RST} ${DIM}mo${RST} ${PINK}%s${RST}" "$t_str" "$w_str" "$m_str")")

# Duration (only visible at 60+ min, color-coded by severity)
if [ "$total_duration" -gt 0 ]; then
  total_min=$(( total_duration / 60000 ))
  # Format as Xh Ym when >= 60 min, otherwise just Xm
  if [ "$total_min" -ge 60 ]; then
    dur_h=$(( total_min / 60 ))
    dur_m=$(( total_min % 60 ))
    dur_str="${dur_h}h${dur_m}m"
  else
    dur_str="${total_min}m"
  fi
  if [ "$total_min" -ge 180 ]; then
    line2+=("$(printf "${RED}⚠  %s${RST}" "$dur_str")")
  elif [ "$total_min" -ge 120 ]; then
    line2+=("$(printf "${RED} %s${RST}" "$dur_str")")
  elif [ "$total_min" -ge 60 ]; then
    line2+=("$(printf "${YELLOW} %s${RST}" "$dur_str")")
  fi
fi

# ── Render ──────────────────────────────────────────────────────────────────
sep1="$(printf " ${DIM}│${RST} ")"
sep2="$(printf " ${DIM}┊${RST} ")"

join_segments() {
  local sep="$1"; shift
  local result=""
  for seg in "$@"; do
    if [ -z "$result" ]; then
      result="$seg"
    else
      result="${result}${sep}${seg}"
    fi
  done
  printf '%b' "$result"
}

printf '%b\n' "$(join_segments "$sep1" "${line1[@]}")"
printf '%b\n' "$(join_segments "$sep2" "${line2[@]}")"
