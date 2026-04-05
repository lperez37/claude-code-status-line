#!/usr/bin/env bash
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SYSTEMD_DIR="$HOME/.config/systemd/user"

RST='\033[0m'; GREEN='\033[32m'; CYAN='\033[36m'; YELLOW='\033[33m'

info()  { printf "${CYAN}[info]${RST}  %s\n" "$1"; }
ok()    { printf "${GREEN}[ok]${RST}    %s\n" "$1"; }
warn()  { printf "${YELLOW}[warn]${RST}  %s\n" "$1"; }

printf "\nClaude Code Status Line — uninstaller\n\n"

# Remove systemd timer
if systemctl --user is-active claude-cost-tracker.timer &>/dev/null 2>&1; then
  systemctl --user disable --now claude-cost-tracker.timer 2>/dev/null
  ok "systemd timer disabled"
fi
rm -f "$SYSTEMD_DIR/claude-cost-tracker.service" "$SYSTEMD_DIR/claude-cost-tracker.timer"
systemctl --user daemon-reload 2>/dev/null || true

# Remove cron entry
if command -v crontab &>/dev/null && crontab -l 2>/dev/null | grep -qF "cost-tracker.sh"; then
  crontab -l 2>/dev/null | grep -vF "cost-tracker.sh" | crontab -
  ok "Cron job removed"
fi

# Remove scripts
rm -f "$CLAUDE_DIR/statusline-command.sh" "$CLAUDE_DIR/cost-tracker.sh" "$CLAUDE_DIR/cost-cache.json"
ok "Scripts and cache removed"

# Remove statusLine from settings
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
if [ -f "$SETTINGS_FILE" ] && jq -e '.statusLine' "$SETTINGS_FILE" &>/dev/null; then
  tmp=$(mktemp)
  jq 'del(.statusLine)' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
  ok "statusLine removed from settings.json"
fi

printf "\nUninstall complete. Restart Claude Code to apply.\n\n"
