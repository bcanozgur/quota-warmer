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
        case .claude: return "claude --model haiku --effort low --no-session-persistence -p 'hi'"
        case .codex:  return "codex exec --model gpt-5.4-mini -c model_reasoning_effort=\"low\" --skip-git-repo-check --ephemeral --ignore-rules 'hi'"
        }
    }

    var fallbackWarmupCommand: String? {
        switch self {
        case .claude:
            return nil
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
}
