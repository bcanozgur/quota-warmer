import CryptoKit
import Foundation
import Security

final class CredentialStore {
    private let fileManager = FileManager.default

    func credential(for tool: ToolID) async throws -> Credential {
        switch tool {
        case .claude: return try claudeCredential()
        case .codex: return try codexCredential()
        }
    }

    private func claudeCredential() throws -> Credential {
        let services = claudeKeychainServices()
        for service in services {
            if let data = keychainPassword(service: service),
               let credential = parseClaudeCredential(data, source: "Keychain \(service)") {
                return credential
            }
        }

        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: url),
           let credential = parseClaudeCredential(data, source: "~/.claude/.credentials.json") {
            return credential
        }

        throw CredentialError.missing("Claude")
    }

    private func codexCredential() throws -> Credential {
        let paths = [
            ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("auth.json") },
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".config/codex/auth.json"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        ].compactMap { $0 }

        for url in paths {
            if let data = try? Data(contentsOf: url),
               let credential = parseCodexCredential(data, source: displayPath(url)) {
                return credential
            }
        }

        if let data = keychainPassword(service: "Codex Auth"),
           let credential = parseCodexCredential(data, source: "Keychain Codex Auth") {
            return credential
        }

        throw CredentialError.missing("Codex")
    }

    private func claudeKeychainServices() -> [String] {
        var services = ["Claude Code-credentials"]
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            let hash = SHA256.hash(data: Data(configDir.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            services.append("Claude Code-credentials-\(hash)")
            services.append("Claude Code-credentials-\(String(hash.prefix(16)))")
        }
        return services
    }

    private func keychainPassword(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func parseClaudeCredential(_ data: Data, source: String) -> Credential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let accessToken = string(in: json, keys: ["access_token", "accessToken", "claudeAiOauth.accessToken", "oauth.accessToken"])
        let refreshToken = string(in: json, keys: ["refresh_token", "refreshToken", "claudeAiOauth.refreshToken", "oauth.refreshToken"])
        let expiresAt = date(in: json, keys: ["expires_at", "expiresAt", "claudeAiOauth.expiresAt", "oauth.expiresAt"])

        guard let token = accessToken, !token.isEmpty else { return nil }
        return Credential(accessToken: token, refreshToken: refreshToken, accountID: nil, source: source, expiresAt: expiresAt)
    }

    private func parseCodexCredential(_ data: Data, source: String) -> Credential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let accessToken = string(in: json, keys: [
            "access_token", "accessToken", "chatgpt_access_token",
            "tokens.access_token", "tokens.accessToken", "auth.access_token"
        ])
        let refreshToken = string(in: json, keys: ["refresh_token", "refreshToken", "tokens.refresh_token"])
        let accountID = string(in: json, keys: [
            "account_id", "accountId", "chatgpt_account_id",
            "ChatGPT-Account-Id", "tokens.account_id", "auth.account_id"
        ])
        let expiresAt = date(in: json, keys: ["expires_at", "expiresAt", "tokens.expires_at", "tokens.expiresAt"])

        guard let token = accessToken, !token.isEmpty else { return nil }
        return Credential(accessToken: token, refreshToken: refreshToken, accountID: accountID, source: source, expiresAt: expiresAt)
    }

    private func string(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = value(in: object, dottedKey: key) {
                if let string = value as? String, !string.isEmpty { return string }
                if let number = value as? NSNumber { return number.stringValue }
            }
        }
        return nil
    }

    private func date(in object: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = value(in: object, dottedKey: key) else { continue }
            if let seconds = value as? TimeInterval {
                return seconds > 10_000_000_000
                    ? Date(timeIntervalSince1970: seconds / 1000)
                    : Date(timeIntervalSince1970: seconds)
            }
            if let number = value as? NSNumber {
                let seconds = number.doubleValue
                return seconds > 10_000_000_000
                    ? Date(timeIntervalSince1970: seconds / 1000)
                    : Date(timeIntervalSince1970: seconds)
            }
            if let string = value as? String {
                if let seconds = TimeInterval(string) {
                    return seconds > 10_000_000_000
                        ? Date(timeIntervalSince1970: seconds / 1000)
                        : Date(timeIntervalSince1970: seconds)
                }
                if let date = ISO8601DateFormatter().date(from: string) { return date }
            }
        }
        return nil
    }

    private func value(in object: [String: Any], dottedKey: String) -> Any? {
        let parts = dottedKey.split(separator: ".").map(String.init)
        var current: Any = object
        for part in parts {
            guard let dict = current as? [String: Any], let next = dict[part] else { return nil }
            current = next
        }
        return current
    }

    private func displayPath(_ url: URL) -> String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        if url.path.hasPrefix(home) {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }
}
