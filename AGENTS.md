# Repository Guidelines

## Project Structure & Module Organization
`Sources/QuotaWarmer/` contains the app code. `Views/` holds the SwiftUI screens and menu bar UI, `Services/` contains log scanning, scheduling, notifications, updates, and warmup execution, and `Models/` holds shared types. Assets live in `Sources/QuotaWarmer/Assets.xcassets/`, and app configuration is in `Sources/QuotaWarmer/Info.plist`. The Xcode project is generated from `project.yml`; do not hand-edit `QuotaWarmer.xcodeproj/`.

## Build, Test, and Development Commands
- `brew install xcodegen` installs the project generator required by this repo.
- `xcodegen generate` regenerates the Xcode project from `project.yml`.
- `open QuotaWarmer.xcodeproj` opens the app in Xcode for day-to-day development.
- `xcodebuild -project QuotaWarmer.xcodeproj -scheme QuotaWarmer build` performs a CLI build.
- `scripts/Install.command` copies a built `QuotaWarmer.app` into `/Applications` and removes quarantine.

## Coding Style & Naming Conventions
Follow the existing Swift style: 4-space indentation, `PascalCase` for types, `camelCase` for methods and properties, and `UPPER_SNAKE_CASE` only for constants when needed. Keep SwiftUI views small and grouped by feature, matching the current `Views/` layout. There is no configured SwiftLint or SwiftFormat rule set, so keep changes visually consistent with nearby files.

## Testing Guidelines
There is no automated test target in the current tree. Verify changes by building the app and manually checking the affected flow, especially menu bar behavior, settings persistence, warmup execution, and update checks. If tests are added later, place them under a `Tests/` directory and name them `QuotaWarmerTests`.

## Commit & Pull Request Guidelines
Recent commits are short, imperative, and specific, often starting with verbs like `Fix`, `Add`, `Remove`, or `Redesign` (for example, `Fix window duration: connect setting to scheduler`). Keep commit messages in that style. Pull requests should include a brief summary, the reason for the change, and verification notes. Add screenshots or screen recordings for UI changes and call out any behavior that affects log access, notifications, or launch-at-login.

## Security & Configuration Tips
This app reads local Claude Code and Codex log files and may launch shell commands. Avoid committing secrets, paths unique to your machine, or ad hoc local debug settings. Update behavior through `project.yml` and source files rather than editing generated project files directly.

## Product Memory
- Keep the menu bar UI compact and close to OpenUsage: provider glyphs, sparse labels, 5h and weekly quota only, and no explanatory marketing text in the popover.
- The menubar label should show the selected/most relevant active tool, a red/green run-state dot, and the 5h window countdown; never let weekly reset time drive the menubar countdown.
- Quota percentages and progress bars should show remaining quota, not used quota, across the whole app.
- Provider detail screens should allow Active/Passive changes separately from manual Warm.
- Keep the menubar label extremely compact: provider glyph, visible active dot, optional hourglass, and countdown/remaining text. Do not place raw provider SVG assets directly in the MenuBarExtra label; render them through a small template/raster glyph so they cannot overflow.
- Keep the popover scaled down and compact; the current visual target is roughly 70% of the earlier QuotaWarmer panel size.
- Automatic quota checks should only fetch active tools by default to avoid unnecessary Claude Keychain prompts when Claude Code is not configured or subscribed.
- History should stay lightweight: collapsible in the main panel and capped to the latest 10 events.
