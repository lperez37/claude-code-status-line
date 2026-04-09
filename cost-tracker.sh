#!/usr/bin/env bash
# Claude Code Cost Tracker
# Aggregates per-message costs from Claude Code JSONL transcripts into a cache.
# Run periodically via cron or systemd timer. The statusline reads the cache.
#
# Correctness notes:
#   1. Each API response is logged once per content block in the JSONL, so we
#      dedupe on .message.id before summing.
#   2. `<synthetic>` assistant messages are system placeholders with no real
#      tokens — they are filtered out.
#   3. Each message is priced using its own .message.model (sessions can mix
#      Opus/Sonnet/Haiku).
#   4. Each message is bucketed by its own .timestamp, not the session's first
#      timestamp — resumed/long-running sessions land on the correct day.
#   5. .message.usage.input_tokens already excludes cached tokens; it is not
#      adjusted further.

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

today=$(date '+%Y-%m-%d')
week_ago=$(date -d '7 days ago' '+%Y-%m-%d')
month_ago=$(date -d '30 days ago' '+%Y-%m-%d')

# Stream all assistant lines from every JSONL file into one jq pipeline.
# Includes both main session files (depth 1) and sub-agent transcripts
# (depth 3, under SESSION/subagents/agent-*.jsonl) — sub-agents are real
# API calls billed separately from the parent session.
# jq does global dedup on .message.id, applies per-message pricing using
# that message's own model, then rolls up by date bucket.
#
# TZ is forwarded explicitly so jq's strflocaltime resolves to the user's
# local date — matching the shell $today/$week/$month markers computed
# above. Without this, messages near midnight land on the wrong day.
find "$PROJECTS_DIR" -name "*.jsonl" -type f 2>/dev/null \
  -exec grep -h '"type":"assistant"' {} + 2>/dev/null \
  | TZ="${TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}" \
    jq -s --arg today "$today" --arg week "$week_ago" --arg month "$month_ago" '
    # Keep only real API responses that carry an id and a model
    map(select(
      .type == "assistant"
      and (.message.id // null) != null
      and (.message.model // null) != null
      and .message.model != "<synthetic>"
    ))
    # Collapse duplicate rows per msg.id. Claude Code writes one JSONL row
    # per content block while streaming an API response. Intermediate rows
    # have stop_reason = null and carry a partial/early output_tokens count;
    # the final row has stop_reason set and carries the true total usage
    # returned by the API. Taking the max across all copies selects the
    # final row (verified: when a completion row exists, max(output_tokens)
    # equals the completion row’s value in 100% of observed cases).
    # (ccusage picks the first-seen row and systematically undercounts
    # output tokens by ~50%; unique_by would do the same.)
    | group_by(.message.id)
    | map({
        # Local date from each message’s own timestamp. Drop fractional
        # seconds ("...975Z" → "Z") because jq’s fromdateiso8601 rejects them.
        date: (.[0].timestamp
               | sub("\\.[0-9]+Z$"; "Z")
               | fromdateiso8601
               | strflocaltime("%Y-%m-%d")),
        model: .[0].message.model,
        in:  (map(.message.usage.input_tokens // 0)               | max),
        out: (map(.message.usage.output_tokens // 0)              | max),
        cr:  (map(.message.usage.cache_read_input_tokens // 0)    | max),
        cw:  (map(.message.usage.cache_creation_input_tokens // 0) | max)
      })
    # Per-message cost using that message’s own model
    # Pricing per 1M tokens (Opus 4.5+/4.6, Sonnet 4.6, Haiku 4.5 — April 2026)
    | map(
        . as $m
        | (if ($m.model | test("opus"; "i"))  then {i: 5, o: 25, cr: 0.50, cw: 6.25}
           elif ($m.model | test("haiku"; "i")) then {i: 1, o: 5,  cr: 0.10, cw: 1.25}
           else                                      {i: 3, o: 15, cr: 0.30, cw: 3.75} end) as $p
        | $m + {
            cost: (($m.in * $p.i + $m.out * $p.o + $m.cr * $p.cr + $m.cw * $p.cw) / 1000000)
          }
      )
    # Aggregate
    | {
        updated: (now | todate),
        total_messages: length,
        all_time: (map(.cost) | add // 0 | . * 100 | round / 100),
        today:  ([.[] | select(.date == $today)] | map(.cost) | add // 0 | . * 100 | round / 100),
        week:   ([.[] | select(.date >= $week)]  | map(.cost) | add // 0 | . * 100 | round / 100),
        month:  ([.[] | select(.date >= $month)] | map(.cost) | add // 0 | . * 100 | round / 100),
        by_model: (
          group_by(.model)
          | map({
              model: .[0].model,
              cost: (map(.cost) | add // 0 | . * 100 | round / 100),
              messages: length
            })
          | sort_by(-.cost)
        ),
        by_day: (
          group_by(.date)
          | map({date: .[0].date, cost: (map(.cost) | add // 0 | . * 100 | round / 100)})
          | sort_by(.date)
          | .[-14:]
        )
      }
  ' > "$CACHE_FILE" 2>/dev/null

echo "Cost cache updated: $CACHE_FILE"
jq . "$CACHE_FILE"
