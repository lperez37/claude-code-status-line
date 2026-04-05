#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SYSTEMD_DIR="$HOME/.config/systemd/user"

# ── Colors ──────────────────────────────────────────────────────────────────
RST='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
GREEN='\033[32m'; CYAN='\033[36m'; YELLOW='\033[33m'; RED='\033[31m'

info()  { printf "${CYAN}[info]${RST}  %s\n" "$1"; }
ok()    { printf "${GREEN}[ok]${RST}    %s\n" "$1"; }
warn()  { printf "${YELLOW}[warn]${RST}  %s\n" "$1"; }
err()   { printf "${RED}[err]${RST}   %s\n" "$1"; }

# ── Preflight checks ───────────────────────────────────────────────────────
printf "\n${BOLD}Claude Code Status Line${RST} — installer\n\n"

for cmd in jq git bash; do
  if ! command -v "$cmd" &>/dev/null; then
    err "$cmd is required but not found. Please install it first."
    exit 1
  fi
done
ok "Dependencies found (jq, git, bash)"

if [ ! -d "$CLAUDE_DIR" ]; then
  err "$CLAUDE_DIR does not exist. Is Claude Code installed?"
  exit 1
fi
ok "Claude Code directory found"

# ── Install scripts ─────────────────────────────────────────────────────────
info "Installing statusline.sh -> $CLAUDE_DIR/statusline-command.sh"
cp "$SCRIPT_DIR/statusline.sh" "$CLAUDE_DIR/statusline-command.sh"
chmod +x "$CLAUDE_DIR/statusline-command.sh"

info "Installing cost-tracker.sh -> $CLAUDE_DIR/cost-tracker.sh"
cp "$SCRIPT_DIR/cost-tracker.sh" "$CLAUDE_DIR/cost-tracker.sh"
chmod +x "$CLAUDE_DIR/cost-tracker.sh"

ok "Scripts installed"

# ── Configure Claude Code settings ──────────────────────────────────────────
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
  # Check if statusLine is already configured
  if jq -e '.statusLine' "$SETTINGS_FILE" &>/dev/null; then
    existing=$(jq -r '.statusLine.command // ""' "$SETTINGS_FILE")
    if [ "$existing" = "bash ~/.claude/statusline-command.sh" ]; then
      ok "settings.json already configured"
    else
      warn "statusLine already configured with a different command: $existing"
      printf "  Overwrite? [y/N] "
      read -r answer
      if [[ "$answer" =~ ^[Yy]$ ]]; then
        tmp=$(mktemp)
        jq '.statusLine = {"type": "command", "command": "bash ~/.claude/statusline-command.sh"}' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
        ok "settings.json updated"
      else
        warn "Skipped settings.json update"
      fi
    fi
  else
    tmp=$(mktemp)
    jq '. + {"statusLine": {"type": "command", "command": "bash ~/.claude/statusline-command.sh"}}' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
    ok "statusLine added to settings.json"
  fi
else
  cat > "$SETTINGS_FILE" <<'EOF'
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
EOF
  ok "Created settings.json with statusLine"
fi

# ── Set up cost tracker scheduling ──────────────────────────────────────────
info "Setting up cost tracker to run every 15 minutes..."

setup_systemd() {
  mkdir -p "$SYSTEMD_DIR"
  cp "$SCRIPT_DIR/systemd/claude-cost-tracker.service" "$SYSTEMD_DIR/"
  cp "$SCRIPT_DIR/systemd/claude-cost-tracker.timer" "$SYSTEMD_DIR/"
  systemctl --user daemon-reload
  systemctl --user enable --now claude-cost-tracker.timer
  ok "systemd timer enabled (every 15 min)"
}

setup_cron() {
  local cron_entry="*/15 * * * * bash ~/.claude/cost-tracker.sh >/dev/null 2>&1"
  if crontab -l 2>/dev/null | grep -qF "cost-tracker.sh"; then
    ok "Cron job already exists"
  else
    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
    ok "Cron job installed (every 15 min)"
  fi
}

if command -v systemctl &>/dev/null && systemctl --user status &>/dev/null 2>&1; then
  setup_systemd
elif command -v crontab &>/dev/null; then
  setup_cron
else
  warn "Neither systemd user units nor crontab available."
  warn "You'll need to run cost-tracker.sh manually or set up your own scheduler."
fi

# ── Initial cost cache build ────────────────────────────────────────────────
info "Building initial cost cache..."
bash "$CLAUDE_DIR/cost-tracker.sh" >/dev/null 2>&1 && ok "Cost cache built" || warn "Cost cache build failed (will retry on next timer run)"

# ── Done ────────────────────────────────────────────────────────────────────
printf "\n${BOLD}${GREEN}Installation complete!${RST}\n\n"
printf "  Restart Claude Code to see the status line.\n"
printf "  Run ${DIM}bash ~/.claude/cost-tracker.sh${RST} to manually refresh costs.\n\n"
