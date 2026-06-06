---
name: quotawarmer-quota-correctness
description: Use for QuotaWarmer Claude/Codex quota parsing, warm-up timing, web-vs-app quota mismatches, credential/source-health bugs, and any change touching QuotaProvider, MetricExtractor, QuotaMetric, ToolID warmup commands, CredentialStore, WarmupRunner, or scripts/quota-extractor-regression.swift.
---

# QuotaWarmer Quota Correctness

Use this skill when correctness depends on live quota semantics, payload parsing, warm-up timing, credentials, rate limits, or app-vs-web mismatch reports.

## Agent Pairing

Use this skill with `.agents/agents/quotawarmer-quota-engineer.md` for implementation work. Use `.agents/agents/quotawarmer-runtime-verifier.md` after a user-visible fix needs independent installed-app proof.

## Principles

- Do not trust labels alone. Compare against real payload shape, reset timestamps, used/remaining semantics, and the app's selected `QuotaMetric`.
- Do not fabricate quota values. Local logs and cached/fallback state are display context only; automatic warm-up decisions must use fresh live server quota data.
- Keep changes surgical. Every edited line should trace to the mismatch, parser bug, credential path, or warm-up safety requirement.
- Turn every bug into a payload-shaped regression case before calling it fixed.

## Orientation

Inspect these first:

- `Sources/QuotaWarmer/Services/QuotaProvider.swift`
- `Sources/QuotaWarmer/Models/QuotaModels.swift`
- `Sources/QuotaWarmer/Models/ToolID.swift`
- `Sources/QuotaWarmer/Services/CredentialStore.swift`
- `Sources/QuotaWarmer/Services/WarmupRunner.swift`
- `Sources/QuotaWarmer/AppState.swift`
- `scripts/quota-extractor-regression.swift`

Use `codegraph_context` first for flow questions, then read only the specific files needed.

## Debug Workflow

1. State the concrete mismatch: provider, shown app value, expected web/API value, and exact reset/percentage.
2. Identify the authoritative source: Claude OAuth usage, Codex `wham/usage`, Keychain/file credential source, or local log display context.
3. Inspect the current payload parser path and selection scoring; check zero values, numeric scale, reset date parsing, and weekly-vs-5h classification.
4. Add or update a regression in `scripts/quota-extractor-regression.swift` using the smallest representative payload.
5. Patch parser/state behavior narrowly. Avoid changing UI copy or warm-up policy unless the evidence requires it.

## Verification Commands

Compile and run the regression gate:

```bash
rtk swiftc -module-cache-path /tmp/QuotaWarmerQuotaModuleCache -parse-as-library Sources/QuotaWarmer/Models/ToolID.swift Sources/QuotaWarmer/Models/QuotaModels.swift Sources/QuotaWarmer/Services/CredentialStore.swift Sources/QuotaWarmer/Services/WarmupRunner.swift Sources/QuotaWarmer/Services/QuotaProvider.swift scripts/quota-extractor-regression.swift -o /tmp/quota-extractor-regression
rtk /tmp/quota-extractor-regression
```

If app code changed, also run the Debug build:

```bash
rtk xcodebuild -project QuotaWarmer.xcodeproj -scheme QuotaWarmer -configuration Debug -derivedDataPath /tmp/QuotaWarmerDerivedData -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

For live bugs, verify current external state with a targeted probe or command before concluding. If sandbox blocks Keychain/network/process access, rerun the same command with approval instead of guessing.
