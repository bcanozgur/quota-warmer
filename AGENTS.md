# Repository Guidelines

## Project Structure & Module Organization

QuotaWarmer is a macOS SwiftUI menu bar app generated with XcodeGen. Source lives in `Sources/QuotaWarmer/`: `Models/` contains quota and tool types, `Services/` owns quota fetching, scheduling, notifications, updates, and warm-up commands, and `Views/` contains the menu bar label, popover, provider tabs, and settings UI. Assets are in `Sources/QuotaWarmer/Assets.xcassets`; app metadata is in `Sources/QuotaWarmer/Info.plist`. `project.yml` is the authoritative project definition, so do not hand-edit `QuotaWarmer.xcodeproj`.

## Build, Test, and Development Commands

- `rtk xcodegen generate` regenerates `QuotaWarmer.xcodeproj` after source or project config changes.
- `rtk xcodebuild -project QuotaWarmer.xcodeproj -scheme QuotaWarmer -configuration Debug -derivedDataPath /tmp/QuotaWarmerDerivedData -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build` builds the app locally without signing.
- `rtk scripts/local-package.command` builds a local Release app, installs it to `/Applications`, clears quarantine, and launches it.
- `rtk swiftc -module-cache-path /tmp/QuotaWarmerQuotaModuleCache -parse-as-library Sources/QuotaWarmer/Models/ToolID.swift Sources/QuotaWarmer/Models/QuotaModels.swift Sources/QuotaWarmer/Services/CredentialStore.swift Sources/QuotaWarmer/Services/WarmupRunner.swift Sources/QuotaWarmer/Services/QuotaProvider.swift scripts/quota-extractor-regression.swift -o /tmp/quota-extractor-regression` compiles the parser regression executable; run it with `rtk /tmp/quota-extractor-regression`.

## Coding Style & Naming Conventions

Use Swift 5.9 conventions: 4-space indentation, `PascalCase` for types, `camelCase` for methods and properties, and small focused SwiftUI views. Prefer existing service boundaries over new globals. Keep comments short and only where behavior is non-obvious, especially around quota-source semantics and warm-up safety.

## Testing Guidelines

There is no standalone XCTest target. The primary regression gate is `scripts/quota-extractor-regression.swift`, which protects live quota payload parsing, fallback behavior, and warm-up command assumptions. Add payload-shaped cases whenever changing `QuotaProvider`, `MetricExtractor`, `ToolID`, `CredentialStore`, or `WarmupRunner`.

## Commit & Pull Request Guidelines

Commit messages in this repo are concise, imperative, and specific, for example `Fix Codex and Claude quota extraction` or `Show both tools in the menu bar with a per-tool pin`. PRs should describe behavior changes, list verification commands, and include screenshots for UI changes to the menu bar label or popover.

## Security & Configuration Tips

Never commit credentials, tokens, Keychain exports, or local auth files such as `~/.claude/.credentials.json` and `~/.codex/auth.json`. Automatic warm-up must rely on fresh live quota data; local activity logs are display context only.

## Agent-Specific Instructions

Use project skills under `.agents/skills/` for non-trivial work: `quotawarmer-quota-correctness` for quota/warm-up semantics and `quotawarmer-macos-runtime` for menu bar runtime/UI verification.

Project agents live under `.agents/agents/`. Use `quotawarmer-quota-engineer` for quota and warm-up fixes, and `quotawarmer-runtime-verifier` for independent proof that a user-visible macOS fix is installed and running.
