import CryptoKit
import Foundation
import Security

final class CredentialStore {
    private let fileManager = FileManager.default

    func credential(
        for tool: ToolID,
        allowsUserInteraction: Bool = false
    ) async throws -> Credential {
        switch tool {
        case .claude:
            return try claudeCredential(allowsUserInteraction: allowsUserInteraction)
        case .codex: return try codexCredential()
        }
    }

    private func claudeCredential(allowsUserInteraction: Bool) throws -> Credential {
        // Claude Code owns its Keychain item and rotates the access token inside
        // it roughly every 8 hours. Mirror the still-valid token into an item
        // QuotaWarmer itself owns so the common path touches nothing foreign.
        if let cached = cachedClaudeCredential(), !cached.isExpired {
            DiagnosticLogger.append("claude_credential_source=mirror prompt=no")
            return cached
        }

        let services = claudeKeychainServices()

        // The mirror aged out with the token, so a fresh one has to come from
        // Claude Code's own item. Read it the way Claude Code wrote it — see
        // securityToolPassword for why that read is the one that never prompts.
        for service in services {
            guard let data = securityToolPassword(service: service),
                  let credential = parseClaudeCredential(data, source: "Keychain \(service)") else { continue }
            DiagnosticLogger.append("claude_credential_source=security-tool prompt=no")
            storeCachedClaudeCredential(credential)
            return credential
        }

        DiagnosticLogger.append("claude_credential_source=claude-code-keychain prompt=possible")
        var keychainNeedsApproval = false
        for service in services {
            switch claudeKeychainPassword(service: service, allowsUserInteraction: allowsUserInteraction) {
            case .data(let data):
                if let credential = parseClaudeCredential(data, source: "Keychain \(service)") {
                    storeCachedClaudeCredential(credential)
                    return credential
                }
            case .interactionRequired:
                keychainNeedsApproval = true
            case .notFound:
                break
            }
        }

        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return Credential(
                accessToken: token,
                refreshToken: nil,
                accountID: nil,
                source: "env CLAUDE_CODE_OAUTH_TOKEN",
                expiresAt: nil
            )
        }

        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: url),
           let credential = parseClaudeCredential(data, source: "~/.claude/.credentials.json") {
            return credential
        }

        if keychainNeedsApproval {
            // Reaching here means even `/usr/bin/security` could not read the
            // item, so approving the dialog would only buy one token rotation.
            // Record the one-time repair (adds our partition to the item) so the
            // user is not left guessing why "Always Allow" never sticks.
            DiagnosticLogger.append(
                "claude_keychain_blocked remedy=\"security set-generic-password-partition-list "
                    + "-S apple-tool:,apple:,teamid:55K26JK98Y -s 'Claude Code-credentials' -a $USER\""
            )
            throw CredentialError.interactionRequired("Claude")
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

    func credentialSourceSummary(for tool: ToolID) -> String {
        switch tool {
        case .claude:
            return (claudeKeychainServices().map { "Keychain \($0)" } + [
                "env CLAUDE_CODE_OAUTH_TOKEN",
                "~/.claude/.credentials.json"
            ]).joined(separator: ", ")
        case .codex:
            return [
                "$CODEX_HOME/auth.json",
                "~/.config/codex/auth.json",
                "~/.codex/auth.json",
                "Keychain Codex Auth"
            ].joined(separator: ", ")
        }
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
        // Codex quota polling is always a background task, so this read must
        // fail rather than raise a dialog if the item belongs to another app.
        let status = Self.withoutKeychainDialogs {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Generic-password item created and owned by QuotaWarmer. Because this
    /// process added it, SecItemCopyMatching returns it without an approval
    /// dialog, which is the whole point of mirroring the token here.
    private static let claudeCacheService = "com.quotawarmer.app.claude-oauth-cache"

    private struct CachedClaudeCredential: Codable {
        let accessToken: String
        let expiresAt: Date?
        let source: String
    }

    /// Returns the mirrored credential, or nil when absent/unreadable/malformed.
    /// Never throws: a bad cache must always fall through to the real source.
    private func cachedClaudeCredential() -> Credential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.claudeCacheService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        // Owned by this app, so it normally reads straight through — but a
        // mirror written by an older, differently signed build no longer
        // matches the ACL. Never let that corner turn into a dialog; an
        // unreadable mirror simply falls through to the real source.
        let status = Self.withoutKeychainDialogs {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let cached = try? JSONDecoder().decode(CachedClaudeCredential.self, from: data) else {
            return nil
        }
        return Credential(
            accessToken: cached.accessToken,
            // Deliberately not mirrored: QuotaWarmer never refreshes Claude's
            // rotating refresh token, so it has no reason to hold a copy.
            refreshToken: nil,
            accountID: nil,
            // Marked so the diagnostics log distinguishes a prompt-free mirror
            // read from a read that had to touch Claude Code's own item.
            source: "\(cached.source) (cached)",
            expiresAt: cached.expiresAt
        )
    }

    private func storeCachedClaudeCredential(_ credential: Credential) {
        // An access token with no known expiry can never be aged out, so it is
        // not safe to mirror — always re-read those from the owning source.
        guard credential.expiresAt != nil else { return }
        let cached = CachedClaudeCredential(
            accessToken: credential.accessToken,
            expiresAt: credential.expiresAt,
            source: credential.source
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.claudeCacheService
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Cache only needs to be readable while the user is logged in, and
            // must never sync to another machine.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    /// Drops the mirror so the next read goes back to Claude Code's own item.
    /// Used when the mirrored token is rejected by the API.
    func invalidateCachedClaudeCredential() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.claudeCacheService
        ]
        SecItemDelete(query as CFDictionary)
    }

    private enum ClaudeKeychainRead {
        case data(Data)
        case notFound
        case interactionRequired
    }

    /// Serializes the process-wide user-interaction flag below.
    private static let interactionLock = NSLock()

    /// Runs `body` with the login-keychain approval dialog turned off.
    ///
    /// The flag is process-wide, so it is held for exactly one call and restored
    /// through `defer` on every exit path. The SecKeychain family is deprecated
    /// but is the only API that governs this dialog — `kSecUseAuthenticationContext`
    /// reaches only the data-protection keychain — so the deprecation warnings
    /// this raises are expected and must not be "fixed" away.
    private static func withoutKeychainDialogs<T>(_ body: () -> T) -> T {
        interactionLock.lock()
        var previous: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(false)
        defer {
            SecKeychainSetUserInteractionAllowed(previous.boolValue)
            interactionLock.unlock()
        }
        return body()
    }

    /// Background quota polling must never summon a macOS password dialog.
    /// A user-initiated Refresh is the only path allowed to request access.
    private func claudeKeychainPassword(service: String, allowsUserInteraction: Bool) -> ClaudeKeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status: OSStatus
        if allowsUserInteraction {
            status = SecItemCopyMatching(query as CFDictionary, &item)
        } else {
            // `kSecUseAuthenticationContext`/LAContext governs only the
            // data-protection keychain. Claude Code's item lives in the legacy
            // login keychain, whose ACL dialog it does not suppress at all —
            // measured 2026-08-20, a background poll still opened the password
            // window. SecKeychainSetUserInteractionAllowed(false) is the flag
            // that turns that dialog into an immediate error. It is
            // process-wide, so hold it for the shortest window and restore it.
            status = Self.withoutKeychainDialogs {
                SecItemCopyMatching(query as CFDictionary, &item)
            }
        }
        if status == errSecSuccess, let data = item as? Data {
            return .data(data)
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            return .interactionRequired
        }
        return .notFound
    }

    /// Reads Claude Code's credential item by running `/usr/bin/security`.
    ///
    /// Why a subprocess instead of SecItemCopyMatching: since macOS Sierra a
    /// keychain item carries a *partition list* on top of its trusted-app list,
    /// and both must match or macOS demands the login password. Claude Code
    /// writes its item with the `security` tool, so the item's partition list is
    /// `apple-tool:` and `/usr/bin/security` sits in its ACL. QuotaWarmer's
    /// partition is `teamid:…`, which never matches — and clicking "Always
    /// Allow" only appends another trusted app, it never adds the partition.
    /// That is why the dialog came back on every token rotation no matter how
    /// often it was approved (verified against the live item on 2026-08-20).
    /// Reading through the tool the item already trusts is silent, and grants
    /// QuotaWarmer nothing the user's own shell could not already read.
    private func securityToolPassword(service: String) -> Data? {
        let toolPath = "/usr/bin/security"
        guard fileManager.isExecutableFile(atPath: toolPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = ["find-generic-password", "-w", "-s", service]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Should the ACL ever stop trusting the tool, `security` would sit on a
        // password dialog instead of returning. Kill it so a stuck prompt can
        // never outlive this read; the in-process path then reports the failure.
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()

        guard process.terminationStatus == 0 else { return nil }
        // `security -w` appends a newline; never log or return the payload itself.
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return Data(text.utf8)
    }

    private func parseClaudeCredential(_ data: Data, source: String) -> Credential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let accessToken = string(in: json, keys: ["access_token", "accessToken", "claudeAiOauth.accessToken", "oauth.accessToken"])
        let refreshToken = string(in: json, keys: ["refresh_token", "refreshToken", "claudeAiOauth.refreshToken", "oauth.refreshToken"])
        let expiresAt = date(in: json, keys: ["expires_at", "expiresAt", "claudeAiOauth.expiresAt", "oauth.expiresAt"])

        guard let token = accessToken, !token.isEmpty else { return nil }
        return Credential(
            accessToken: token,
            refreshToken: refreshToken,
            accountID: nil,
            source: source,
            expiresAt: expiresAt
        )
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
        return Credential(
            accessToken: token,
            refreshToken: refreshToken,
            accountID: accountID,
            source: source,
            expiresAt: expiresAt
        )
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
