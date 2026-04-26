# Codex Usage Meter

A tiny macOS menu bar app that keeps your OpenAI Codex **and** Anthropic Claude Code usage limits visible while you work.

Codex Usage Meter reads the local Codex session logs already stored on your Mac for Codex usage, and reuses your existing `claude` CLI login to fetch Claude usage from Anthropic's OAuth API. No extra login, browser tab, API key, or background network polling beyond a single periodic Claude usage call.

> Unofficial project. Not affiliated with OpenAI or Anthropic.

![Codex Usage Meter preview](docs/menu-preview.svg)

## What It Shows

- A compact menu bar label like `Cdx 92% · Cld 87%`
- Codex 5-hour and weekly usage gauges (from local session logs)
- Codex local token estimates for the latest turn, latest model call, and last 3 minutes
- Codex last-change estimate based on the previous distinct snapshot
- Claude 5-hour, weekly, and (when applicable) weekly Opus usage gauges
- Reset times for every window
- Shortcuts to the official Codex and Claude usage dashboards
- A small CLI status output covering both providers

## Why

Codex is easiest to use when you can see your remaining usage at a glance. The official dashboard is useful, but it lives in a browser. This app puts the important part directly in the macOS menu bar.

## Requirements

- macOS 13 or newer
- Swift toolchain, included with Xcode Command Line Tools
- For Codex gauges: OpenAI Codex installed and used at least once, with local session files under `~/.codex/sessions`
- For Claude gauges: the `claude` CLI installed and signed in (`claude login`); the app reads the existing OAuth credentials from `~/.claude/.credentials.json` or the macOS Keychain item `Claude Code-credentials`

Either provider is optional — if only one is present, the app shows what it can.

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
Cld 5h 67% left (reset 2026-04-26 15:39 GMT+9) | weekly 55% left (reset 2026-04-27 03:00 GMT+9)
```

## How It Works

### Codex
Codex stores session JSONL files locally. Some events include a `rate_limits` object with the current Codex usage snapshot. Codex Usage Meter scans the newest session files, finds the latest snapshot, and renders it as a menu bar meter.

The Codex path does not read your prompts for display, upload your data, or call any remote API. It only reads local Codex files on your machine.

The "last change" line compares the newest rate-limit snapshot with the previous distinct snapshot. It is a practical estimate of how much the visible usage meter moved after recent Codex activity, not an official per-message bill.

The token lines use Codex's local `token_count` events. "Last turn" estimates the tokens used since the newest turn started. "3m" estimates the token growth over the last three minutes. "Latest call" shows the most recent model call recorded in the local log.

### Claude
For Claude, the local `claude` CLI does not write rate-limit snapshots to disk, so the app calls Anthropic's `GET https://api.anthropic.com/api/oauth/usage` endpoint once per refresh tick using the OAuth access token already issued to the `claude` CLI on this machine.

The token is loaded from `~/.claude/.credentials.json` if present, otherwise from the macOS Keychain item `Claude Code-credentials`. The app never writes credentials and never sends them anywhere except `api.anthropic.com`. The first Keychain read may trigger a one-time "Allow access?" prompt; clicking *Always Allow* makes future reads silent.

If the access token was issued without the `user:profile` scope (some headless `claude setup-token` flows), the usage endpoint refuses the call. Re-running `claude login` interactively re-issues a token with the required scope.

## Limitations

- macOS only. The menu bar UI uses AppKit and `NSStatusItem`.
- Codex usage shows as percentages because Codex local logs expose usage percentages, not an absolute token balance.
- Per-turn and recent-window token counts are local estimates from Codex session logs, not official billing records.
- If Codex changes its local log format, or Anthropic changes its OAuth usage endpoint, the parser may need an update.
- If you have never opened Codex on the machine, there may be no Codex snapshot to display yet. Likewise for Claude if you have never run `claude login`.

## Privacy

- No telemetry, no analytics
- For Codex: only local files under `~/.codex/sessions` are read
- For Claude: a single `GET` to `api.anthropic.com/api/oauth/usage` per refresh tick (about once per minute), authenticated with the OAuth access token that the `claude` CLI already stored locally
- No API key collection, no third-party hosting, no GitHub login

The only other external actions are the optional menu items that open the official Codex and Claude usage dashboards in your browser.

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
