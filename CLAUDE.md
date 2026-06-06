# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

QuotaWarmer is a macOS menu bar app (SwiftUI, `LSUIElement`/agent app) that watches Claude Code and Codex CLI rolling 5-hour quota windows and can auto-send a minimal warm-up command (`hi`) the moment a fresh window opens, so the window isn't wasted. There is no Swift Package — the Xcode project is generated from `project.yml` by XcodeGen.

## Commands

```bash
# Project must be (re)generated whenever project.yml or the file tree changes
xcodegen generate

# Build (CLI)
xcodebuild -project QuotaWarmer.xcodeproj -scheme QuotaWarmer build

# Build a local Release, replace /Applications/QuotaWarmer.app, strip quarantine, launch
scripts/local-package.command
```

### Tests

The only automated test is the quota-extractor regression in `scripts/quota-extractor-regression.swift`. It is **not** an XCTest target — it's compiled standalone with `swiftc` against a hand-picked subset of source files (see `.github/workflows/ci.yml`). To run it locally, compile `Models/ToolID.swift`, `Models/QuotaModels.swift`, `Services/CredentialStore.swift`, `Services/QuotaProvider.swift`, and the script together, then run the binary. It exits non-zero on failure and prints which assertion failed. **Add a case here whenever you touch quota parsing** — it's the safety net for the heuristic extractor and the Codex `wham/usage` parser.

CI (`ci.yml`) runs on macOS with Xcode 16.3: regression test → Debug build → Release build.

## Project skills and subagents

Claude Code project skills live in `.claude/skills/`, and project subagents live in `.claude/agents/`.

- Use `quotawarmer-quota-correctness` / `quotawarmer-quota-engineer` for quota parsing, credential, warm-up timing, and web-vs-app mismatch work.
- Use `quotawarmer-macos-runtime` / `quotawarmer-runtime-verifier` for menu bar UI, build/install/launch, and installed-app runtime proof.

The subagents preload their matching skills through Claude Code's `skills:` frontmatter field. Keep detailed workflow rules in the skills; keep the agents focused on role, tool scope, handoff rules, and output contract.

## Architecture

`AppState` (`Sources/QuotaWarmer/AppState.swift`) is the `@MainActor` brain. Everything flows through it; the Services are stateless-ish helpers it owns, and the Views observe it.

- **`AppState` + `ToolState`** — `AppState` holds one `ToolState` per `ToolID` (`.claude`, `.codex`). `ToolState` is the per-tool published model (active flag, menu-bar pin, snapshot, health, warm-up logs). `isActive` ("active" = auto-warm enabled) and `menuBarVisible` (pin) are independent and each persist to `UserDefaults` keyed by `tool.rawValue`. Most user settings live in `UserDefaults` read through computed properties (`refreshInterval`, `morningHour`, `windowDurationSecs`, `rateLimitGuard`, etc.), not a settings struct.
- **`QuotaProvider`** — fetches live quota over HTTP. Claude: `api.anthropic.com/api/oauth/usage` (OAuth bearer, auto-refreshes the token via `platform.claude.com` on 401). Codex: `chatgpt.com/backend-api/wham/usage` (the `rateLimits/read` app-server path is unreachable with a bearer token). The reset decision is made **only** from these fresh snapshots — local CLI logs are display context, never a warm-up trigger.
- **`MetricExtractor`** (in QuotaProvider.swift) — a generic recursive JSON walker that finds usage/limit/percent/reset fields anywhere in an arbitrary payload and scores candidates to pick the 5-hour vs weekly metric. The Codex `wham/usage` response is parsed by a **dedicated** `codexSnapshot`/`codexWindowMetric` path because its `used_percent` is on a 0–100 scale (1 = 1% used) which the generic extractor would misread as 100% used. Keep that distinction in mind when editing either path.
- **`CredentialStore`** — reads tokens from Keychain, env, and on-disk JSON. Claude: Keychain service `Claude Code-credentials` (+ `CLAUDE_CONFIG_DIR`-hashed variants), `CLAUDE_CODE_OAUTH_TOKEN`, then `~/.claude/.credentials.json`. Codex: `$CODEX_HOME`/`~/.config/codex`/`~/.codex` `auth.json` then Keychain. Lookups tolerate many key spellings and dotted paths.
- **`WarmupRunner`** — runs the warm-up CLI via `/bin/zsh -lc` in an isolated, cleared temp dir (`QuotaWarmerWarmup`), 60s timeout. It resolves the CLI by probing common install dirs + `command -v`, because a GUI agent app has a minimal `PATH`. Commands and the Codex fallback model live on `ToolID.warmupCommand` / `fallbackWarmupCommand`.
- **`Scheduler`** — per-tool `DispatchSourceTimer`s plus an `NSWorkspace.didWakeNotification` observer that fires `onWake` (morning bookkeeping) then `onFire` for every tool on system wake.
- **`WakeScheduler`** — manages a daily `pmset repeat wakeorpoweron` schedule so a sleeping Mac wakes to start a fresh morning window. Requires root, obtained per-change through a single `osascript ... with administrator privileges` prompt (no persistent helper). Best-effort on battery + closed lid; surfaces `isOnACPower()` to warn the user.
- **Views** — `MenuBarLabel` (the menu-bar status), `MenuContent` (popover), `MainTabView`/`ToolTabView`/`SettingsTabView`, `OnboardingView` (shown when a CLI is missing), `DS.swift` (design tokens).

### Key behavioral rules (easy to break)

- **Auto-warm gating**: a warm-up only fires when the tool `isActive`, not `globalPassive`, the snapshot is `fresh`, `canAutoWarmFromSnapshot` is true (≥95% remaining or reset within 60s), and the snapshot's `rawWindowKey` differs from the last auto-warmed window (`lastAutoWindowKey`). This dedup is what prevents repeated warm-ups in the same window — preserve it.
- **`rawWindowKey`** identifies a quota window (source + 5h reset time + remaining fraction). It's the dedup key; changing how it's built changes warm-up triggering.
- **Freshness** is purely snapshot age: ≤5 min fresh, ≤30 min stale, else expired (`QuotaSnapshot.freshness`).
- **Backoff**: failed warm-ups set `backoffUntil` with exponential backoff (5 min → ×2, cap 30 min), respected when `rateLimitGuard` is on.
- **Claude auth recheck**: Claude quota auth failures schedule short automatic rechecks (15s, 45s, 90s) so a just-completed `claude auth login` or Claude Code prompt can recover without waiting for the normal quota timer. Do not make this loop unbounded.
- **Morning pre-warm** is deduplicated to once per calendar day (`lastMorningWarmDay`) and routed through `runMorningWarmup` from both the in-app timer and the wake handler. A late wake (>15 min) is a "caught up" warm and notifies the user.
- Two timers run continuously: a quota refresh timer (`refreshInterval`, default 300s) and a 1s UI timer that pokes `objectWillChange` so countdowns tick. The menu-bar label observes `AppState` (not each `ToolState`), so toggles that must refresh it (e.g. pin) route through `AppState` methods like `setMenuBarVisible`.

## Conventions

- All UI/state types are `@MainActor`; network and process work is `async` off the main actor and results are applied back on `AppState`.
- New persisted settings: add a `UserDefaults` computed property on `AppState` and, if it affects scheduling, call the matching `apply*`/`reschedule*` method so live timers pick it up.
- Errors surfaced to the user go through the typed `QuotaProviderError` / `WarmupError` / `CredentialError` enums and are mapped to `SourceHealth`/`AuthStatus` + a `HistoryEvent` in `applyQuotaError`.
- History events are mirrored to `/tmp/quotawarmer-diagnostics.log` through `DiagnosticLogger`. Keep this file diagnostic-only: never write raw bearer tokens, auth headers, or warm-up command output that might contain secrets.

## Release

Tag `vMAJOR.MINOR.PATCH` triggers `.github/workflows/release.yml`, which validates the tag against `CFBundleShortVersionString` in `project.yml`, builds, signs + notarizes the DMG, and publishes `latest.json` (consumed by `UpdateChecker`). The version string in `project.yml` is the source of truth — bump it with the tag.
