# QuotaWarmer

> Keep your Claude Code and Codex CLI quota windows alive — automatically.

---

Claude Code and Codex CLI use a **5-hour rolling quota window** that starts when you send your first message. If you open the tool late, you burn a big chunk of that window doing nothing.

QuotaWarmer sits in your menu bar, watches both tools' log files, and sends a minimal `hi` message right when each window resets — so your next 5 hours start the moment you need them, not when you remember to open a terminal.

## Features

- **Automatic warm-up** — sends `claude -p 'hi'` or `codex exec 'hi'` exactly when the window resets
- **Accurate window tracking** — reads log timestamps to find the true window start, not just the last activity
- **Live countdown** — per-tool timers visible directly in the menu bar
- **Manual trigger** — activate any window on demand with one click
- **Auto-Warm toggle** — enable or disable automatic triggering per tool
- **Prompt log** — terminal-style history of every warmup command and its output
- **Notifications** — optional alerts 30 min before a window expires and on successful activation
- **Update checker** — notified in-app when a new version is available on GitHub
- **Launch at Login** — starts silently on macOS login, stays out of your way
- **No dependencies** — pure Swift + SwiftUI, no third-party packages

## How it works

```
~/.claude/projects/*/*.jsonl      ← Claude Code session logs
~/.codex/sessions/YYYY/MM/DD/*.jsonl  ← Codex CLI session logs
```

QuotaWarmer reads the earliest message timestamp in the current window to determine exactly when the 5-hour clock started. When that clock hits zero, it spawns a login shell (`/bin/zsh -lc`) so your `PATH` is fully loaded, then runs the warmup command. The new window starts immediately — before you've even opened your terminal.

## Install

1. Download the latest `QuotaWarmer.dmg` from [Releases](https://github.com/bcanozgur/quota-warmer/releases)
2. Open the DMG and drag **QuotaWarmer.app** to Applications
3. Double-click **Install.command** inside the DMG — this removes the macOS quarantine flag and opens the app

> The app is ad-hoc signed (no Apple Developer ID). The install script runs `xattr -cr` to clear Gatekeeper's quarantine so the app opens without warnings. Alternatively: **System Settings → Privacy & Security → Open Anyway**.

## Build from source

**Requirements:** macOS 14+, Xcode 16+, [xcodegen](https://github.com/yonaskolb/XcodeGen)

```bash
brew install xcodegen
git clone https://github.com/bcanozgur/quota-warmer.git
cd quota-warmer
xcodegen generate
open QuotaWarmer.xcodeproj
```

## Requirements

| | |
|---|---|
| macOS | 14.0 Sonoma or later |
| Claude Code | [Install](https://docs.anthropic.com/en/docs/claude-code) |
| Codex CLI | [Install](https://github.com/openai/codex) |

Claude Code and Codex must be accessible via your shell `PATH`. QuotaWarmer will show a setup prompt on first launch if either CLI is missing.

## License

MIT
