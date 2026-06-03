# QuotaWarmer

> Keep your Claude Code and Codex CLI quota windows alive — automatically.

---

Claude Code and Codex CLI use a **5-hour rolling quota window** that starts when you send your first message. If you open the tool late, you burn a big chunk of that window doing nothing.

QuotaWarmer sits in your menu bar, checks fresh server quota snapshots, and sends a minimal `hi` message with the cheapest configured model right when each window resets — so your next 5 hours start the moment you need them, not when you remember to open a terminal.

## Features

- **Automatic warm-up** — sends `claude --model haiku --effort low --no-session-persistence -p 'hi'` or `codex exec --model 5.4-mini -c model_reasoning_effort="low" --skip-git-repo-check --ephemeral --ignore-rules 'hi'` after a fresh server reset signal. If `5.4-mini` is not available for the signed-in ChatGPT account, QuotaWarmer retries Codex once with the configured default model and low reasoning effort.
- **Accurate quota tracking** — uses live quota sources for reset decisions, with local logs kept as display-only context
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

QuotaWarmer reads server quota snapshots to decide whether an automatic warmup is safe. Stale quota and local logs can be shown in the UI, but they do not trigger automatic messages. When a fresh reset signal arrives, it prepares an empty app-owned directory under `/tmp`, spawns a login shell (`/bin/zsh -lc`) from that directory so your `PATH` is fully loaded, then runs the warmup command without project files, rules, or persisted Codex/Claude session context.

## Install

1. Download the latest `QuotaWarmer-<version>-universal.dmg` from [Releases](https://github.com/bcanozgur/quota-warmer/releases)
2. Open the DMG and drag **QuotaWarmer.app** to Applications
3. Open **QuotaWarmer** from Applications

GitHub release builds are signed and notarized. Local development builds may still require this once in Terminal:

```bash
xattr -cr /Applications/QuotaWarmer.app
```

## Build from source

**Requirements:** macOS 14+, Xcode 16+, [xcodegen](https://github.com/yonaskolb/XcodeGen)

```bash
brew install xcodegen
git clone https://github.com/bcanozgur/quota-warmer.git
cd quota-warmer
xcodegen generate
open QuotaWarmer.xcodeproj
```

## Release

Releases are built by GitHub Actions from `vMAJOR.MINOR.PATCH` tags. The release workflow validates the tag against `project.yml`, builds the macOS app, signs and notarizes the DMG, uploads `latest.json`, and verifies release assets.

Required repository secrets:

| Secret | Purpose |
|---|---|
| `APPLE_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` |
| `APPLE_SIGNING_IDENTITY` | Developer ID Application signing identity |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_PASSWORD` | App-specific password for notarization |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `KEYCHAIN_PASSWORD` | Temporary CI keychain password |

## Requirements

| | |
|---|---|
| macOS | 14.0 Sonoma or later |
| Claude Code | [Install](https://docs.anthropic.com/en/docs/claude-code) |
| Codex CLI | [Install](https://github.com/openai/codex) |

Claude Code and Codex must be accessible via your shell `PATH`. QuotaWarmer will show a setup prompt on first launch if either CLI is missing.

## License

MIT
