# QuotaWarmer

QuotaWarmer is a compact macOS menu bar app that manages your Claude Code and Codex CLI capacity — it keeps your own rolling quota windows in view and, when you ask it to, ready to use the moment they reset.

By default it only **monitors**: it watches live quota snapshots and shows each provider's window directly in the menu bar. Switch a tool to **Auto-warm** and it will also send a single minimal warm-up command through your own logged-in CLI the instant a fresh 5-hour window opens — then verify the window actually started.

![QuotaWarmer menu bar popover](docs/images/quota-warmer-menu.png)

## Highlights

- **Three modes per tool**: **Off**, **Monitor only** (watch quota, never send anything — the default), or **Auto-warm** (claim fresh windows automatically).
- **Menu bar status at a glance**: provider glyph, mode/health dot, 5-hour countdown, and remaining quota percentage.
- **Claude Code and Codex CLI support**: each provider is monitored, refreshed, and warmed independently.
- **Live quota tracking**: reset decisions use fresh server quota snapshots; local logs are used only as display context.
- **Window claim receipt**: after a warm-up, QuotaWarmer re-checks quota to confirm the window actually opened — so "sent" never quietly means "missed."
- **Liveness watchdog**: if the app ever stops checking quota, the menu bar and popover say so instead of looking healthy.
- **Manual controls**: refresh quota or warm a provider directly from the popover.
- **Lightweight history**: recent quota checks, warm-ups, claim confirmations, update checks, and failures are visible without leaving the menu.
- **Notifications and update checks**: optional quota-window reminders plus in-app release availability.
- **Launch at login**: runs quietly as a menu bar utility.

## Is this allowed?

QuotaWarmer uses capacity you already pay for, through the official CLI you're already signed into. It never bypasses or raises your limits, never shares or uploads your credentials, and sends nothing at all for tools left on Monitor or Off. Providers may change their APIs at any time; if automated warm-up is ever disallowed, set a tool to Monitor and QuotaWarmer keeps tracking your quota.

## How It Works

Claude Code and Codex CLI use rolling quota windows. If a window starts only when you remember to open the CLI, part of the available time can be wasted.

QuotaWarmer keeps the app running in the menu bar and periodically checks quota state for monitored providers. For a tool set to Auto-warm, when a fresh reset is detected it runs a minimal warm-up command from an isolated temporary working directory:

```bash
claude --model haiku --effort low --no-session-persistence -p 'hi'
codex exec --model gpt-5.4-mini -c model_reasoning_effort="low" --skip-git-repo-check --ephemeral --ignore-rules 'hi'
```

If `gpt-5.4-mini` is unavailable for the signed-in Codex account, QuotaWarmer retries once with the configured default Codex model and low reasoning effort.

Local activity is scanned from:

```text
~/.claude/projects/*/*.jsonl
~/.codex/sessions/YYYY/MM/DD/*.jsonl
```

These logs help the UI show context, but stale local activity does not trigger automatic warm-ups.

## Requirements

| Dependency | Requirement |
| --- | --- |
| macOS | 14.0 Sonoma or later |
| Xcode | 16+ for local builds |
| Claude Code | Installed and available on your shell `PATH` |
| Codex CLI | Installed and available on your shell `PATH` |

QuotaWarmer shows setup guidance on first launch if a required CLI is missing.

## Install

### Homebrew (recommended)

```bash
brew install --cask bcanozgur/tap/quotawarmer
```

Update later with `brew upgrade --cask quotawarmer`.

### Manual download

1. Download the latest `QuotaWarmer-<version>-universal.dmg` from [Releases](https://github.com/bcanozgur/quota-warmer/releases).
2. Open the DMG and drag **QuotaWarmer.app** to **Applications**.
3. Launch **QuotaWarmer** from Applications.

### First launch (Gatekeeper)

QuotaWarmer is ad-hoc signed but **not Apple-notarized**, so macOS quarantines it on
download. Clear the quarantine once after installing:

```bash
xattr -dr com.apple.quarantine "/Applications/QuotaWarmer.app"
```

…or right-click **QuotaWarmer.app** in Applications and choose **Open** the first time.

## Build From Source

Install XcodeGen, generate the project, and open it in Xcode:

```bash
brew install xcodegen
git clone https://github.com/bcanozgur/quota-warmer.git
cd quota-warmer
xcodegen generate
open QuotaWarmer.xcodeproj
```

CLI build:

```bash
xcodebuild -project QuotaWarmer.xcodeproj -scheme QuotaWarmer build
```

Build a local Release app, replace any existing `/Applications/QuotaWarmer.app`, clear quarantine, and launch it:

```bash
scripts/local-package.command
```

## Project Structure

```text
Sources/QuotaWarmer/
  Models/       Shared app and quota types
  Services/     Quota checks, scheduling, notifications, updates, warm-up commands
  Views/        SwiftUI menu bar label, popover, provider, and settings screens
  Assets.xcassets/
project.yml     XcodeGen project definition
scripts/        Local install and packaging helpers
```

## Release Process

Releases are built by GitHub Actions from `vMAJOR.MINOR.PATCH` tags. The release workflow validates the tag against `project.yml`, builds the macOS app, signs and notarizes the DMG, uploads `latest.json`, and verifies release assets.

Required repository secrets:

| Secret | Purpose |
| --- | --- |
| `APPLE_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` |
| `APPLE_SIGNING_IDENTITY` | Developer ID Application signing identity |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_PASSWORD` | App-specific password for notarization |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `KEYCHAIN_PASSWORD` | Temporary CI keychain password |

## License

MIT
