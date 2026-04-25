#!/usr/bin/env bash
set -euo pipefail

BIN_PATH="$HOME/.local/bin/codex-usage-meter"
PLIST_PATH="$HOME/Library/LaunchAgents/io.github.sangdonlee.codex-usage-meter.plist"
LABEL="io.github.sangdonlee.codex-usage-meter"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH" "$BIN_PATH"

echo "Codex Usage Meter has been removed."
echo "Logs, if any, remain in ~/.local/state/codex-usage-meter."
