import CryptoKit
import Foundation

/// One watched account of one CLI. The built-in account (`accountID ==
/// "default"`) is the CLI's normal home (`~/.claude`, `~/.codex`); every other
/// account lives in its own home directory, which the CLI is pointed at through
/// `CLAUDE_CONFIG_DIR` / `CODEX_HOME`. Separate homes are what let two
/// accounts stay signed in side by side: each has its own token, Keychain item
/// and logs, so neither login overwrites the other.
///
/// Identity is `kind` + `accountID` only; `name` is display text and may be
/// renamed without the account becoming a different dictionary key.
struct ProviderID: Hashable, Identifiable, CustomStringConvertible {
    static let defaultAccountID = "default"

    let kind: ToolID
    let accountID: String
    /// Absolute home directory for a non-default account; nil for the default.
    let home: String?
    var name: String

    init(kind: ToolID, accountID: String = ProviderID.defaultAccountID, home: String? = nil, name: String? = nil) {
        self.kind = kind
        self.accountID = accountID
        self.home = accountID == Self.defaultAccountID ? nil : home
        self.name = name ?? ""
    }

    /// The CLI's built-in account.
    static func `default`(_ kind: ToolID) -> ProviderID { ProviderID(kind: kind) }

    var isDefault: Bool { accountID == Self.defaultAccountID }
    var id: String { storageKey }
    var description: String { storageKey }

    /// Suffix for every per-account `UserDefaults` key and identifier. The
    /// default account keeps the bare tool name, so installs from before
    /// multi-account support keep all their settings and dedup state.
    var storageKey: String { isDefault ? kind.rawValue : "\(kind.rawValue).\(accountID)" }

    /// Kept so per-tool key builders (`"toolMode.\(tool.rawValue)"`) read the
    /// same for accounts as they did for tools.
    var rawValue: String { storageKey }

    /// "Claude", or "Claude · Work" for an added account.
    var shortName: String {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return isDefault || label.isEmpty ? kind.shortName : "\(kind.shortName) · \(label)"
    }

    var displayName: String {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return isDefault || label.isEmpty ? kind.displayName : "\(kind.displayName) · \(label)"
    }

    /// One-letter account initial for glyph badges; nil for the default account.
    var badge: String? {
        guard !isDefault else { return nil }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.first.map { String($0).uppercased() } ?? "+"
    }

    var windowDuration: TimeInterval { kind.windowDuration }
    var weeklyWindowDuration: TimeInterval { kind.weeklyWindowDuration }

    /// Environment variable that points the CLI at this account's home.
    var homeEnvironmentVariable: String {
        switch kind {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex:  return "CODEX_HOME"
        }
    }

    /// `["CLAUDE_CONFIG_DIR": home]` for an added account, empty for the default.
    var cliEnvironment: [String: String] {
        guard let home else { return [:] }
        return [homeEnvironmentVariable: home]
    }

    /// Where this account's CLI writes its JSONL logs.
    var logDirectoryURL: URL? {
        guard let home else { return kind.logDirectoryURL }
        let root = URL(fileURLWithPath: home, isDirectory: true)
        switch kind {
        case .claude: return root.appendingPathComponent("projects")
        case .codex:  return root.appendingPathComponent("sessions")
        }
    }

    /// The login command a user runs once to sign this account in, with the
    /// home already exported. The path is single-quoted for the shell.
    var loginCommand: String {
        let cli = kind == .claude ? "claude auth login" : "codex login"
        guard let home else { return cli }
        return "\(homeEnvironmentVariable)=\(ProviderID.shellQuoted(home)) \(cli)"
    }

    static func == (lhs: ProviderID, rhs: ProviderID) -> Bool {
        lhs.kind == rhs.kind && lhs.accountID == rhs.accountID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(accountID)
    }

    /// Single-quotes `value` for `zsh`, escaping embedded quotes.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Keychain service names Claude Code may have stored this account's
    /// credentials under. Claude Code names the default home's item
    /// `Claude Code-credentials` and a `CLAUDE_CONFIG_DIR` home's item
    /// `Claude Code-credentials-<first 8 hex of sha256(dir)>`; the longer
    /// prefixes are kept as tolerated variants.
    static func claudeKeychainServices(configDir: String?) -> [String] {
        guard let configDir, !configDir.isEmpty else { return ["Claude Code-credentials"] }
        var services: [String] = []
        var seen = Set<String>()
        var paths = [configDir]
        let trimmed = configDir.hasSuffix("/") ? String(configDir.dropLast()) : configDir
        if trimmed != configDir { paths.append(trimmed) }
        for path in paths {
            let hash = SHA256.hash(data: Data(path.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            for length in [8, 16, 64] {
                let service = "Claude Code-credentials-\(hash.prefix(length))"
                if seen.insert(service).inserted { services.append(service) }
            }
        }
        return services
    }
}

/// A user-added account as persisted in `UserDefaults` (`accounts.v1`).
struct ProviderAccount: Codable, Hashable, Identifiable {
    var id: String
    var kind: ToolID
    var name: String
    var home: String

    var providerID: ProviderID {
        ProviderID(kind: kind, accountID: id, home: home, name: name)
    }

    /// Account ids end up in `UserDefaults` keys, notification identifiers and
    /// file names; keep them to a safe alphabet.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id != ProviderID.defaultAccountID && id.count <= 40
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// A home path is interpolated into shell commands (quoted) and hashed into
    /// a Keychain service name, so require an absolute path without control
    /// characters or quotes.
    static func isValidHome(_ home: String) -> Bool {
        home.hasPrefix("/") && home.count > 1
            && !home.contains("'") && !home.contains("\"")
            && !home.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// `~/.claude-work` style default home for a new account, made unique.
    static func suggestedHome(kind: ToolID, name: String, existing: [String], homeDirectory: String = NSHomeDirectory()) -> String {
        let slug = slugified(name).isEmpty ? "account" : slugified(name)
        let base = "\(homeDirectory)/.\(kind.rawValue)-\(slug)"
        var candidate = base
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    static func slugified(_ name: String) -> String {
        // Folding strips accents (ş→s, ğ→g) but leaves letters that are not
        // accented forms, such as the Turkish dotless ı.
        let lowered = name.lowercased()
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "ß", with: "ss")
            .folding(options: .diacriticInsensitive, locale: nil)
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(24))
    }

    static let defaultsKey = "accounts.v1"

    static func load(from defaults: UserDefaults = .standard) -> [ProviderAccount] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ProviderAccount].self, from: data) else { return [] }
        return decoded.filter { isValidID($0.id) && isValidHome($0.home) }
    }

    static func save(_ accounts: [ProviderAccount], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
