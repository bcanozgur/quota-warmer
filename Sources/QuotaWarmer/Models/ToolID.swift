import Foundation

enum ToolID: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex CLI"
        }
    }

    /// Short, brand-only name for in-app screen labels.
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    var icon: String {
        switch self {
        case .claude: return "bolt.circle.fill"
        case .codex:  return "terminal.fill"
        }
    }

    var accentColor: String {
        switch self {
        case .claude: return "orange"
        case .codex:  return "purple"
        }
    }

    /// Claude: `haiku` is the CLI alias for the cheapest current model (Claude
    /// Haiku 4.5, $1/$5 per MTok as of 2026-09-30) and follows future Haiku
    /// releases. Measured 2026-09-30 on CLI 2.1.285: without isolation the
    /// default system prompt (user CLAUDE.md, MCP tool schemas, skills, plugins)
    /// made a single `hi` write ~51K cache tokens plus ~190 thinking tokens;
    /// `--safe-mode`/`--strict-mcp-config`, a one-line system prompt, disabled
    /// thinking and `--effort low` bring it to ~400 input / 5 output tokens.
    /// All of these flags are per-run only — nothing is written to settings.
    ///
    /// The models actually used come from the tool's model catalog
    /// (`ModelCatalogStore.warmupModels`); these are the built-in defaults.
    var warmupCommand: String { warmupCommand(model: defaultWarmupModel) }

    /// Run only when the primary command is rejected for an unknown option
    /// (an older CLI without the isolation flags). Still pinned to a cheap
    /// model, so the fallback can never land on the user's default (e.g. Opus).
    var fallbackWarmupCommand: String? { legacyWarmupCommand(model: defaultWarmupModel) }

    /// Claude: the CLI alias for the cheapest tier. Codex: measured cheapest
    /// per warm-up on a ChatGPT account (2026-09-30: ~15K prompt tokens vs
    /// ~35K for gpt-6-luna, which is cheaper per token).
    var defaultWarmupModel: String {
        switch self {
        case .claude: return "haiku"
        case .codex:  return "gpt-5.6-luna"
        }
    }

    /// `model` must pass `ModelCatalog.isSafeWarmupModel`: it is interpolated
    /// into a `zsh -lc` command line.
    func warmupCommand(model: String) -> String {
        switch self {
        case .claude:
            return "claude --model \(model) --effort low --settings '{\"alwaysThinkingEnabled\":false}' --safe-mode --strict-mcp-config --system-prompt 'Reply with one word.' --no-session-persistence --max-turns 1 --tools '' -p 'hi'"
        case .codex:
            return "codex exec --model \(model) -c model_reasoning_effort=\"low\" --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules 'hi'"
        }
    }

    func legacyWarmupCommand(model: String) -> String? {
        switch self {
        case .claude: return "claude --model \(model) --no-session-persistence --max-turns 1 --tools '' -p 'hi'"
        case .codex:  return nil
        }
    }

    var logDirectoryURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            return home.appendingPathComponent(".claude/projects")
        case .codex:
            return home.appendingPathComponent(".codex/sessions")
        }
    }

    /// Rolling quota window duration. Claude Code is always 5 h server-side;
    /// the setting lets the user adjust if Anthropic ever changes this.
    var windowDuration: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: "windowDurationSecs")
        return stored > 0 ? TimeInterval(stored) : 5 * 3600
    }

    /// Weekly quota window length (7 days). Used by the in-app pace marker to
    /// show how much of the weekly window's *time* remains versus quota.
    var weeklyWindowDuration: TimeInterval { 7 * 24 * 3600 }
}

/// How QuotaWarmer treats a tool. Monitoring (read-only visibility) is the
/// safe default; automatic warm-up is an explicit opt-in on top of it.
///
/// - `.off`      — not watched at all.
/// - `.monitor`  — polls quota and shows status/alerts, but never sends anything.
/// - `.autoWarm` — monitors *and* auto-claims a fresh window.
enum ToolMode: String, CaseIterable, Codable {
    case off
    case monitor
    case autoWarm

    /// Short label for compact controls.
    var label: String {
        switch self {
        case .off:      return "Off"
        case .monitor:  return "Monitor"
        case .autoWarm: return "Auto-warm"
        }
    }

    /// Descriptive label for the dropdown menu items.
    var menuLabel: String {
        switch self {
        case .off:      return "Off — don't watch"
        case .monitor:  return "Monitor only — watch quota"
        case .autoWarm: return "Auto-warm — claim windows"
        }
    }

    /// Next mode when cycling the control: Off → Monitor → Auto-warm → Off.
    var next: ToolMode {
        switch self {
        case .off:      return .monitor
        case .monitor:  return .autoWarm
        case .autoWarm: return .off
        }
    }
}
