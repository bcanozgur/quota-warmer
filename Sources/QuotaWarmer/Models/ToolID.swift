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
        case .claude: return "claude -p 'hi'"
        case .codex:  return "codex exec 'hi'"
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

    var windowDuration: TimeInterval { 5 * 3600 }
}
