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

    var warmupCommand: String {
        switch self {
        case .claude: return "claude --model haiku --effort low --no-session-persistence --max-turns 1 --tools '' -p 'hi'"
        case .codex:  return "codex exec --model gpt-5.4-mini -c model_reasoning_effort=\"low\" --skip-git-repo-check --ephemeral --ignore-rules 'hi'"
        }
    }

    var fallbackWarmupCommand: String? {
        switch self {
        case .claude:
            return "claude --effort low --no-session-persistence --max-turns 1 --tools '' -p 'hi'"
        case .codex:
            return "codex exec -c model_reasoning_effort=\"low\" --skip-git-repo-check --ephemeral --ignore-rules 'hi'"
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
