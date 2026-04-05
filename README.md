# Claude Code Status Line

A two-line status bar for [Claude Code](https://claude.ai/code) that shows session info, real-time API cost tracking, and context window usage.

## What it looks like

```
 ~/project │  main │ 󰊠 Opus 4.6 │  +42  -7 │ ██████░░░░ 58%
true cost $4.21 ┊ today $113 ┊ wk $939 ┊ mo $2.8k
```

### Line 1 — Session info
| Segment | Description |
|---------|-------------|
| ` path` | Current working directory (shortened) |
| ` branch` | Git branch name |
| `󰊠 model` | Active Claude model |
| ` +N  -N` | Lines added/removed this session |
| `[N]` / `[I]` | Vim mode (if enabled) |
| `"name"` | Session name (if set) |
| `██░░ N%` | Context window usage bar (green/orange/red gradient) |

### Line 2 — Cost tracking
| Segment | Description |
|---------|-------------|
| `true cost $X.XX` | This session's cost at API rates (green < $5, yellow < $15, red $15+) |
| `today $X` | Aggregate cost for today (calendar day) |
| `wk $X` | Rolling 7-day cost |
| `mo $X` | Rolling 30-day cost |
| ` Nm` | Session duration — only shown at 60+ min (yellow 60m, red 120m, warning 180m+) |

## Prerequisites

- [Claude Code](https://claude.ai/code) CLI installed (`~/.claude/` must exist)
- `jq` (JSON processor)
- `git`
- Linux with `systemd` (preferred) or `crontab` for scheduled cost updates

## Installation

```bash
git clone https://github.com/YOUR_USER/claude-code-status-line.git
cd claude-code-status-line
bash install.sh
```

The installer will:
1. Copy `statusline.sh` and `cost-tracker.sh` to `~/.claude/`
2. Add the `statusLine` config to `~/.claude/settings.json`
3. Set up a systemd user timer (or cron job) to refresh cost data every 15 minutes
4. Build the initial cost cache

Restart Claude Code after installation.

## How it works

### Status line (`statusline.sh`)
Claude Code pipes a JSON blob to the configured `statusLine` command on every render. The script parses it for session data (model, cost, context usage, etc.) and reads aggregate costs from a local cache file.

### Cost tracker (`cost-tracker.sh`)
Scans all JSONL session transcripts in `~/.claude/projects/`, extracts token usage from assistant messages, and calculates costs using current Anthropic API pricing:

| Model | Input | Output | Cache Read | Cache Write |
|-------|-------|--------|------------|-------------|
| Opus 4.5+ | $5/1M | $25/1M | $0.50/1M | $6.25/1M |
| Sonnet 4.6 | $3/1M | $15/1M | $0.30/1M | $3.75/1M |
| Haiku 4.5 | $1/1M | $5/1M | $0.10/1M | $1.25/1M |

Sessions are bucketed by their **start timestamp** (not file modification time), so a session that runs past midnight is attributed to the day it began.

Results are written to `~/.claude/cost-cache.json`:
```json
{
  "updated": "2026-04-05T14:56:54Z",
  "total_sessions": 527,
  "today": 112.82,
  "week": 939.21,
  "month": 2847.95,
  "all_time": 2847.95,
  "by_model": [...]
}
```

### Scheduling
The cost tracker runs every 15 minutes via a systemd user timer (or cron). You can also run it manually:

```bash
bash ~/.claude/cost-tracker.sh
```

## Uninstall

```bash
cd claude-code-status-line
bash uninstall.sh
```

Removes scripts, cache, systemd timer/cron job, and the `statusLine` entry from settings.

## Customization

### Change refresh interval
Edit `systemd/claude-cost-tracker.timer` and change `OnUnitActiveSec=15min` to your preferred interval, then reinstall. For cron, edit your crontab directly.

### Adjust cost thresholds
In `statusline.sh`, the `cost_colour` function controls session cost coloring:
- Green: < $5
- Yellow: < $15
- Red: $15+

### Adjust duration thresholds
Duration warnings appear at:
- 60 min: yellow
- 120 min: red
- 180 min: red + warning emoji

### Update pricing
If Anthropic changes their API pricing, update the rates in `cost-tracker.sh` in the jq pricing block.

## License

MIT
