#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
LOG_DIR="$HOME/.local/state/codex-usage-meter"
PLIST_DIR="$HOME/Library/LaunchAgents"
BIN_PATH="$BIN_DIR/codex-usage-meter"
PLIST_PATH="$PLIST_DIR/io.github.sangdonlee.codex-usage-meter.plist"
LABEL="io.github.sangdonlee.codex-usage-meter"

cd "$ROOT_DIR"
swift build -c release

mkdir -p "$BIN_DIR" "$LOG_DIR" "$PLIST_DIR"
install -m 755 "$ROOT_DIR/.build/release/codex-usage-meter" "$BIN_PATH"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_PATH</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/stderr.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Codex Usage Meter is running."
echo "Menu bar binary: $BIN_PATH"
echo "LaunchAgent: $PLIST_PATH"
