---
name: quotawarmer-macos-runtime
description: Use for QuotaWarmer macOS SwiftUI menu bar UI changes, build/run/install/debug work, runtime verification, generated Xcode project handling, screenshots, menu bar label behavior, and changes touching Views, AppState UI state, project.yml, assets, scripts/local-package.command, or /Applications/QuotaWarmer.app.
---

# QuotaWarmer macOS Runtime

Use this skill when work affects the menu bar app experience, SwiftUI views, runtime installation, generated project files, or whether the user actually sees the new build.

## Agent Pairing

Use this skill with `.agents/agents/quotawarmer-runtime-verifier.md` for installed-app/runtime proof. Use `.agents/agents/quotawarmer-quota-engineer.md` first when the visible bug starts from quota parsing, credentials, or warm-up semantics.

## Principles

- Treat the running app as authoritative for user-visible bugs. Repo builds do not prove `/Applications/QuotaWarmer.app` is updated.
- Keep UI changes focused on the reported behavior. Do not restyle unrelated panels or refactor adjacent views.
- `project.yml` is authoritative. Regenerate `QuotaWarmer.xcodeproj`; do not hand-edit generated project files.
- Preserve the menu-bar-first app model: `LSUIElement: true`, no Dock-first workflows.

## Orientation

Inspect these first:

- `project.yml`
- `Sources/QuotaWarmer/Views/MenuBarLabel.swift`
- `Sources/QuotaWarmer/Views/MenuContent.swift`
- `Sources/QuotaWarmer/Views/ToolTabView.swift`
- `Sources/QuotaWarmer/Views/MainTabView.swift`
- `Sources/QuotaWarmer/AppState.swift`
- `Sources/QuotaWarmer/Assets.xcassets/`
- `scripts/local-package.command`

Use `codegraph_context` for flow or blast-radius questions before editing.

## Runtime Workflow

1. Confirm current state: `rtk git status --short`, relevant source search, and whether `/Applications/QuotaWarmer.app` is running.
2. Make the smallest source change. If adding/removing files or changing project config, run `rtk xcodegen generate`.
3. Build Debug before installation.
4. For user-visible fixes, build Release, replace the installed app, clear quarantine, restart, and verify the process path.
5. If a bug depends on persisted defaults, inspect or reset only the specific key involved. Never wipe all app defaults casually.

## Verification Commands

Build Debug:

```bash
rtk xcodebuild -project QuotaWarmer.xcodeproj -scheme QuotaWarmer -configuration Debug -derivedDataPath /tmp/QuotaWarmerDerivedData -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Build Release for installation:

```bash
rtk xcodebuild -project QuotaWarmer.xcodeproj -scheme QuotaWarmer -configuration Release -derivedDataPath /tmp/QuotaWarmerReleaseDerivedData -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Install and launch when the user needs the running app fixed:

```bash
rtk ditto /tmp/QuotaWarmerReleaseDerivedData/Build/Products/Release/QuotaWarmer.app /Applications/QuotaWarmer.app
rtk xattr -cr /Applications/QuotaWarmer.app
rtk open /Applications/QuotaWarmer.app
rtk pgrep -lf QuotaWarmer
```

Use screenshots or direct binary/source string checks only as supporting evidence. Final confidence should include build result plus runtime path when the bug is visible in the menu bar.
