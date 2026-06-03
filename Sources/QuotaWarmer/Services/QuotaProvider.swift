import Foundation

protocol QuotaProviding {
    func fetchQuota(for tool: ToolID) async throws -> QuotaSnapshot
}

final class QuotaProvider: QuotaProviding {
    private let credentialStore = CredentialStore()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchQuota(for tool: ToolID) async throws -> QuotaSnapshot {
        switch tool {
        case .claude: return try await fetchClaudeQuota()
        case .codex: return try await fetchCodexQuota()
        }
    }

    private func fetchClaudeQuota() async throws -> QuotaSnapshot {
        var credential: Credential
        do {
            credential = try await credentialStore.credential(for: .claude)
        } catch {
            throw QuotaProviderError.missingCredentials("Claude credentials not found")
        }

        if credential.isExpired, let refreshed = try? await refreshClaudeCredential(credential) {
            credential = refreshed
        }

        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        do {
            let payload = try await requestJSON(url: url, credential: credential)
            return snapshot(tool: .claude, source: "Claude OAuth usage", corroboratingSource: nil, payload: payload, message: credential.source)
        } catch QuotaProviderError.authFailure where credential.refreshToken != nil {
            let refreshed = try await refreshClaudeCredential(credential)
            let payload = try await requestJSON(url: url, credential: refreshed)
            return snapshot(tool: .claude, source: "Claude OAuth usage", corroboratingSource: nil, payload: payload, message: refreshed.source)
        }
    }

    private func refreshClaudeCredential(_ credential: Credential) async throws -> Credential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw QuotaProviderError.authFailure("Claude token expired and no refresh token was found")
        }

        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(urlEncoded(refreshToken))"
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 || status == 403 {
            throw QuotaProviderError.authFailure("Claude authorization expired")
        }
        guard (200..<300).contains(status) else {
            throw QuotaProviderError.unavailable("Claude token refresh failed (\(status))")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String else {
            throw QuotaProviderError.malformed("Claude token refresh response was malformed")
        }
        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue
        return Credential(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String ?? refreshToken,
            accountID: credential.accountID,
            source: credential.source,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) }
        )
    }

    private func fetchCodexQuota() async throws -> QuotaSnapshot {
        let credential: Credential
        do {
            credential = try await credentialStore.credential(for: .codex)
        } catch {
            throw QuotaProviderError.missingCredentials("Codex credentials not found")
        }

        let appServerURL = URL(string: "https://chatgpt.com/backend-api/codex/account/rateLimits/read")!
        let whamURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

        do {
            let payload = try await requestJSON(url: appServerURL, credential: credential)
            let whamSucceeded = (try? await requestJSON(url: whamURL, credential: credential)) != nil
            return snapshot(
                tool: .codex,
                source: "Codex app-server",
                corroboratingSource: whamSucceeded ? "wham usage" : nil,
                payload: payload,
                message: credential.source
            )
        } catch {
            if let whamPayload = try? await requestJSON(url: whamURL, credential: credential) {
                return snapshot(
                    tool: .codex,
                    source: "wham usage fallback",
                    corroboratingSource: nil,
                    payload: whamPayload,
                    message: "Codex app-server unavailable; showing fallback from \(credential.source)"
                )
            }
            throw error
        }
    }

    private func requestJSON(url: URL, credential: Credential) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credential.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return try JSONSerialization.jsonObject(with: data)
            case 401, 403:
                throw QuotaProviderError.authFailure("Authorization failed for \(url.host ?? "quota source")")
            case 429:
                throw QuotaProviderError.rateLimited("Quota source rate limited requests")
            case 500..<600:
                throw QuotaProviderError.unavailable("Quota source is unavailable (\(status))")
            default:
                throw QuotaProviderError.unavailable("Quota source returned HTTP \(status)")
            }
        } catch let error as QuotaProviderError {
            throw error
        } catch {
            throw QuotaProviderError.unavailable("Could not reach quota source")
        }
    }

    private func snapshot(
        tool: ToolID,
        source: String,
        corroboratingSource: String?,
        payload: Any,
        message: String?
    ) -> QuotaSnapshot {
        let metrics = MetricExtractor(payload: payload).metrics()
        let fiveHour = metrics.first { metric in
            let name = metric.name.lowercased()
            return name.contains("5h") || name.contains("5 hour") || name.contains("five") || name.contains("session")
        } ?? metrics.first
        let weekly = metrics.first { metric in
            let name = metric.name.lowercased()
            return name.contains("week") || name.contains("weekly")
        }
        let extras = metrics.filter { metric in
            metric.id != fiveHour?.id && metric.id != weekly?.id
        }
        let keyParts = [
            source,
            fiveHour?.resetAt.map { ISO8601DateFormatter().string(from: $0) } ?? "no-reset",
            fiveHour.map { String(format: "%.3f", $0.remainingPercent ?? (1 - $0.clampedUsed)) } ?? "no-5h"
        ]

        return QuotaSnapshot(
            tool: tool,
            fetchedAt: Date(),
            primarySource: source,
            corroboratingSource: corroboratingSource,
            fiveHour: fiveHour,
            weekly: weekly,
            extras: extras,
            rawWindowKey: keyParts.joined(separator: "|"),
            message: message
        )
    }

    private func urlEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

private struct MetricExtractor {
    let payload: Any

    func metrics() -> [QuotaMetric] {
        var output: [QuotaMetric] = []
        collect(from: payload, path: [], output: &output)
        if output.isEmpty {
            output.append(QuotaMetric(name: "5h quota", usedPercent: 0, remainingPercent: nil, resetAt: nil, detail: "quota source returned no limit fields"))
        }
        return output
    }

    private func collect(from value: Any, path: [String], output: inout [QuotaMetric]) {
        if let dict = value as? [String: Any] {
            if let metric = metric(from: dict, path: path), !containsEquivalent(metric, in: output) {
                output.append(metric)
            }
            for (key, child) in dict {
                collect(from: child, path: path + [key], output: &output)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                collect(from: child, path: path + ["\(index)"], output: &output)
            }
        }
    }

    private func metric(from dict: [String: Any], path: [String]) -> QuotaMetric? {
        var lower: [String: Any] = [:]
        for (key, value) in dict {
            lower[key.lowercased()] = value
        }
        let percent = firstNumber(lower, keys: [
            "used_percent", "usedpercentage", "used_percentage", "percent_used",
            "usage_percent", "usagepercentage", "consumed_percent"
        ])
        let remainingPercent = firstNumber(lower, keys: [
            "remaining_percent", "remainingpercentage", "percent_remaining"
        ])
        let used = firstNumber(lower, keys: ["used", "usage", "consumed", "current"])
        let limit = firstNumber(lower, keys: ["limit", "total", "max", "quota"])

        let usedPercent: Double?
        if let percent {
            usedPercent = normalizePercent(percent)
        } else if let remainingPercent {
            usedPercent = 1 - normalizePercent(remainingPercent)
        } else if let used, let limit, limit > 0 {
            usedPercent = used / limit
        } else {
            usedPercent = nil
        }

        guard let usedPercent else { return nil }
        let resetAt = firstDate(lower, keys: ["reset_at", "resets_at", "resetat", "resetsat", "reset_time", "next_reset_at"])
        let name = firstString(lower, keys: ["name", "type", "window", "model", "bucket", "label"])
            ?? readableName(path: path)
        let detail: String?
        if let used, let limit {
            detail = "\(compactNumber(used)) / \(compactNumber(limit))"
        } else {
            detail = nil
        }

        return QuotaMetric(
            name: name,
            usedPercent: usedPercent,
            remainingPercent: remainingPercent.map(normalizePercent),
            resetAt: resetAt,
            detail: detail
        )
    }

    private func containsEquivalent(_ metric: QuotaMetric, in metrics: [QuotaMetric]) -> Bool {
        metrics.contains { existing in
            existing.name == metric.name && abs(existing.clampedUsed - metric.clampedUsed) < 0.001
        }
    }

    private func firstNumber(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let number = value as? NSNumber { return number.doubleValue }
            if let double = value as? Double { return double }
            if let int = value as? Int { return Double(int) }
            if let string = value as? String, let double = Double(string) { return double }
        }
        return nil
    }

    private func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = dict[key] as? String, !string.isEmpty { return string }
        }
        return nil
    }

    private func firstDate(_ dict: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let string = value as? String, let date = ISO8601DateFormatter().date(from: string) { return date }
            if let number = value as? NSNumber {
                let seconds = number.doubleValue
                return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
            }
        }
        return nil
    }

    private func normalizePercent(_ value: Double) -> Double {
        min(max(value > 1 ? value / 100 : value, 0), 1)
    }

    private func readableName(path: [String]) -> String {
        let useful = path.reversed().first { part in
            Int(part) == nil && !["data", "limits", "usage", "quota", "rate_limits"].contains(part.lowercased())
        }
        return useful?
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized ?? "Quota"
    }

    private func compactNumber(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fm", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return String(format: "%.0f", value)
    }
}
