#!/usr/bin/env bash
# Claude Code Cost Tracker
# Aggregates session costs from Claude Code JSONL transcripts into a cache file.
# Run periodically via cron or systemd timer. The statusline reads the cache.

CACHE_FILE="$HOME/.claude/cost-cache.json"
PROJECTS_DIR="$HOME/.claude/projects"
LOCK_FILE="/tmp/claude-cost-tracker.lock"

# Prevent concurrent runs
if [ -f "$LOCK_FILE" ]; then
  lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
  if [ "$lock_age" -lt 300 ]; then
    exit 0
  fi
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Calculate cost for a single session JSONL file
# Extracts all assistant messages, sums tokens, applies model-specific pricing
session_cost() {
  local file="$1"

  # Extract first timestamp from the JSONL to bucket by session start date
  # Falls back to file mtime if no timestamp found
  local iso_date
  iso_date=$(head -1 "$file" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null | cut -c1-10)
  if [ -z "$iso_date" ]; then
    local mod_date
    mod_date=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    iso_date=$(date -d "@$mod_date" '+%Y-%m-%d' 2>/dev/null)
  fi

  # Extract model and sum all usage from assistant messages
  grep '"type":"assistant"' "$file" 2>/dev/null | jq -s '
    if length == 0 then empty
    else
      (.[0].message.model // "unknown") as $model |
      (map(.message.usage // {}) | {
        input: (map(.input_tokens // 0) | add),
        output: (map(.output_tokens // 0) | add),
        cache_read: (map(.cache_read_input_tokens // 0) | add),
        cache_write: (map(.cache_creation_input_tokens // 0) | add)
      }) as $tokens |
      # Pricing per 1M tokens (Opus 4.5+/4.6, Sonnet 4.6, Haiku 4.5 — April 2025)
      (if ($model | test("opus"; "i")) then {i: 5, o: 25, cr: 0.50, cw: 6.25}
       elif ($model | test("haiku"; "i")) then {i: 1, o: 5, cr: 0.10, cw: 1.25}
       else {i: 3, o: 15, cr: 0.30, cw: 3.75} end) as $prices |
      ([$tokens.input - $tokens.cache_read - $tokens.cache_write, 0] | max) as $regular |
      (($regular * $prices.i + $tokens.output * $prices.o + $tokens.cache_read * $prices.cr + $tokens.cache_write * $prices.cw) / 1000000) as $cost |
      {date: "'"$iso_date"'", model: $model, cost: $cost}
    end
  ' 2>/dev/null
}

# Process all sessions and build cost log
cost_log=""
while IFS= read -r file; do
  result=$(session_cost "$file")
  if [ -n "$result" ]; then
    cost_log="${cost_log}${result}"$'\n'
  fi
done < <(find "$PROJECTS_DIR" -maxdepth 2 -name "*.jsonl" -not -path "*/subagents/*" -type f 2>/dev/null)

# Aggregate into time buckets
today=$(date '+%Y-%m-%d')
week_ago=$(date -d '7 days ago' '+%Y-%m-%d')
month_ago=$(date -d '30 days ago' '+%Y-%m-%d')

echo "$cost_log" | jq -s --arg today "$today" --arg week "$week_ago" --arg month "$month_ago" '
  map(select(. != null)) |
  {
    updated: (now | todate),
    total_sessions: length,
    all_time: (map(.cost) | add // 0 | . * 100 | round / 100),
    today: ([.[] | select(.date == $today)] | map(.cost) | add // 0 | . * 100 | round / 100),
    week: ([.[] | select(.date >= $week)] | map(.cost) | add // 0 | . * 100 | round / 100),
    month: ([.[] | select(.date >= $month)] | map(.cost) | add // 0 | . * 100 | round / 100),
    by_model: (group_by(.model) | map({
      model: .[0].model,
      cost: (map(.cost) | add // 0 | . * 100 | round / 100),
      sessions: length
    }) | sort_by(-.cost))
  }
' > "$CACHE_FILE" 2>/dev/null

echo "Cost cache updated: $CACHE_FILE"
jq . "$CACHE_FILE"
