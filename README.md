# Codex Usage Meter

A tiny macOS menu bar app that keeps your OpenAI Codex usage limits visible while you work.

Codex Usage Meter reads the local Codex session logs already stored on your Mac and shows the latest rate-limit snapshot in the menu bar. No extra login, browser tab, API key, or background network polling is required.

> Unofficial project. Not affiliated with OpenAI.

![Codex Usage Meter preview](docs/menu-preview.svg)

## What It Shows

- A compact menu bar label like `Cdx 92%`
- A visual gauge for the 5-hour Codex usage window
- A visual gauge for the weekly Codex usage window
- Percentage labels beside each gauge
- Last-change estimate based on the previous distinct Codex usage snapshot
- Local token estimates for the latest turn, latest model call, and last 3 minutes
- Reset times for both windows
- A shortcut to the official Codex usage dashboard
- A small CLI status output with local token stats

## Why

Codex is easiest to use when you can see your remaining usage at a glance. The official dashboard is useful, but it lives in a browser. This app puts the important part directly in the macOS menu bar.

## Requirements

- macOS 13 or newer
- Swift toolchain, included with Xcode Command Line Tools
- OpenAI Codex installed and used at least once on this Mac
- Local Codex session files under `~/.codex/sessions`

Install Xcode Command Line Tools if `swift` is missing:

```bash
xcode-select --install
```

## Install

```bash
git clone https://github.com/SangdonLee972/codex-usage-meter.git
cd codex-usage-meter
./scripts/install.sh
```

The installer builds the app, installs the binary to `~/.local/bin/codex-usage-meter`, and registers a user LaunchAgent so it starts automatically when you log in.

## Uninstall

```bash
./scripts/uninstall.sh
```

## CLI

Print the latest local snapshot:

```bash
~/.local/bin/codex-usage-meter --print
```

Example:

```text
Cdx 90% left | weekly 57% left | last change 5h +1% left, weekly no change | last turn 662.0K total (in 660.7K, out 1.3K) | 3m 2.4M total (in 2.4M, out 15.1K) | latest call 128.3K total (in 128.3K, out 59) | 5h reset 2026-04-25 20:50 GMT+9 | weekly reset 2026-04-29 03:20 GMT+9 | local today 43.2M
```

## How It Works

Codex stores session JSONL files locally. Some events include a `rate_limits` object with the current Codex usage snapshot. Codex Usage Meter scans the newest session files, finds the latest snapshot, and renders it as a menu bar meter.

It does not read your prompts for display, upload your data, or call any remote API. It only reads local Codex files on your machine.

The "last change" line compares the newest rate-limit snapshot with the previous distinct snapshot. It is a practical estimate of how much the visible usage meter moved after recent Codex activity, not an official per-message bill.

The token lines use Codex's local `token_count` events. "Last turn" estimates the tokens used since the newest turn started. "3m" estimates the token growth over the last three minutes. "Latest call" shows the most recent model call recorded in the local log.

## Limitations

- macOS only. The menu bar UI uses AppKit and `NSStatusItem`.
- It shows percentage-based usage because Codex local logs expose usage percentages, not a guaranteed absolute token balance.
- Per-turn and recent-window token counts are local estimates from Codex session logs, not official billing records.
- If Codex changes its local log format, the parser may need an update.
- If you have never opened Codex on the machine, there may be no snapshot to display yet.

## Privacy

The app is local-first:

- No telemetry
- No external network calls
- No API key required
- No OpenAI or GitHub login required

The only external action is the optional menu item that opens the official Codex usage dashboard in your browser.

## Development

Build:

```bash
swift build -c release
```

Run from source:

```bash
swift run codex-usage-meter
```

Print status:

```bash
swift run codex-usage-meter --print
```

## Contributing

Issues and pull requests are welcome. Useful areas:

- More resilient Codex log parsing
- Better menu bar icons
- Signed release builds
- Homebrew support
- Support for other platforms through a separate UI

## License

MIT
