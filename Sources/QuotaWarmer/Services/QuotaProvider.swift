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
            return try requireRecognizedMetrics(
                snapshot(tool: .claude, source: "Claude OAuth usage", corroboratingSource: nil, payload: payload, message: credential.source)
            )
        } catch QuotaProviderError.authFailure where credential.refreshToken != nil {
            let refreshed = try await refreshClaudeCredential(credential)
            let payload = try await requestJSON(url: url, credential: refreshed)
            return try requireRecognizedMetrics(
                snapshot(tool: .claude, source: "Claude OAuth usage", corroboratingSource: nil, payload: payload, message: refreshed.source)
            )
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

        // The codex app-server `rateLimits/read` path is not reachable with a
        // bearer token (Cloudflare 403 / 404), so the wham usage endpoint — the
        // same source the Codex web analytics page uses — is the live quota.
        let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let payload = try await requestJSON(url: usageURL, credential: credential)
        return try requireRecognizedMetrics(
            codexSnapshot(payload: payload, source: "Codex usage", message: credential.source)
        )
    }

    private func requestJSON(url: URL, credential: Credential) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if url.host == "api.anthropic.com", url.path == "/api/oauth/usage" {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
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

    private func requireRecognizedMetrics(_ snapshot: QuotaSnapshot) throws -> QuotaSnapshot {
        guard snapshot.fiveHour != nil || snapshot.weekly != nil || !snapshot.extras.isEmpty else {
            throw QuotaProviderError.malformed("Quota source returned no recognizable limit fields")
        }
        return snapshot
    }

    func snapshot(
        tool: ToolID,
        source: String,
        corroboratingSource: String?,
        payload: Any,
        message: String?
    ) -> QuotaSnapshot {
        let metrics = MetricExtractor(payload: payload).metrics()
        let now = Date()
        let weekly = selectWeeklyMetric(from: metrics, now: now)
        let fiveHour = selectFiveHourMetric(from: metrics, excluding: weekly, now: now)
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

    /// Parses the Codex `wham/usage` response, whose `rate_limit` block has a
    /// known shape: `primary_window` (the 5h window) and `secondary_window`
    /// (weekly). `used_percent` is on a 0–100 scale, so a value of `1` means
    /// 1% used — the generic heuristic extractor mis-reads that as 100% used,
    /// hence the explicit parse here. Falls back to the generic extractor if
    /// the response doesn't carry the expected windows.
    func codexSnapshot(payload: Any, source: String, message: String?) -> QuotaSnapshot {
        if let rateLimit = (payload as? [String: Any])?["rate_limit"] as? [String: Any],
           rateLimit["primary_window"] != nil || rateLimit["secondary_window"] != nil {
            let fiveHour = codexWindowMetric(rateLimit["primary_window"], defaultName: "5h")
            let weekly = codexWindowMetric(rateLimit["secondary_window"], defaultName: "Weekly")
            let keyParts = [
                source,
                fiveHour?.resetAt.map { ISO8601DateFormatter().string(from: $0) } ?? "no-reset",
                fiveHour.map { String(format: "%.3f", $0.remainingFraction) } ?? "no-5h"
            ]
            return QuotaSnapshot(
                tool: .codex,
                fetchedAt: Date(),
                primarySource: source,
                corroboratingSource: nil,
                fiveHour: fiveHour,
                weekly: weekly,
                extras: [],
                rawWindowKey: keyParts.joined(separator: "|"),
                message: message
            )
        }

        return snapshot(
            tool: .codex,
            source: source,
            corroboratingSource: nil,
            payload: payload,
            message: message
        )
    }

    private func codexWindowMetric(_ value: Any?, defaultName: String) -> QuotaMetric? {
        guard let window = value as? [String: Any],
              let usedRaw = codexDouble(window["used_percent"]) else { return nil }
        let usedPercent = min(max(usedRaw / 100, 0), 1)

        let resetAt: Date?
        if let epoch = codexDouble(window["reset_at"]), epoch > 0 {
            resetAt = Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
        } else if let after = codexDouble(window["reset_after_seconds"]), after > 0 {
            resetAt = Date().addingTimeInterval(after)
        } else {
            resetAt = nil
        }

        let windowSeconds = codexDouble(window["limit_window_seconds"]) ?? 0
        let name: String
        if windowSeconds >= 6 * 24 * 3600 {
            name = "Weekly"
        } else if windowSeconds > 0 && windowSeconds <= 6 * 3600 {
            name = "5h"
        } else {
            name = defaultName
        }

        return QuotaMetric(
            name: name,
            usedPercent: usedPercent,
            remainingPercent: 1 - usedPercent,
            resetAt: resetAt,
            detail: nil,
            context: name.lowercased()
        )
    }

    private func codexDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func urlEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func selectWeeklyMetric(from metrics: [QuotaMetric], now: Date) -> QuotaMetric? {
        bestMetric(from: metrics) { metric in
            let text = quotaText(metric)
            var score = 0
            if text.contains("weekly") || text.contains("week") || text.contains("sevenday") || text.contains("7day") {
                score += 100
            }
            if text.contains("allmodels") || text.contains("all models") { score += 8 }
            if metric.remainingPercent != nil { score += 5 }
            if let resetAt = metric.resetAt {
                let seconds = resetAt.timeIntervalSince(now)
                if seconds > 24 * 3600 { score += 45 }
                if seconds > 8 * 24 * 3600 { score -= 25 }
                if seconds > 0 { score += 3 }
            }
            if text.contains("5h") || text.contains("5hour") || text.contains("5 hour") || text.contains("session") {
                score -= 80
            }
            return score
        }
    }

    private func selectFiveHourMetric(from metrics: [QuotaMetric], excluding weekly: QuotaMetric?, now: Date) -> QuotaMetric? {
        let candidates = metrics.filter { $0.id != weekly?.id }
        if let best = bestMetric(from: candidates, minimumScore: 30, scoredBy: { metric in
            let text = quotaText(metric)
            var score = 0
            if text.contains("5h") || text.contains("5hour") || text.contains("5 hour")
                || text.contains("fivehour") || text.contains("five hour") {
                score += 120
            }
            if text.contains("session") || text.contains("current") {
                score += 70
            }
            if metric.remainingPercent != nil { score += 6 }
            if let resetAt = metric.resetAt {
                let seconds = resetAt.timeIntervalSince(now)
                if seconds > 0 && seconds <= 8 * 3600 { score += 55 }
                if seconds > 24 * 3600 { score -= 120 }
            }
            if text.contains("weekly") || text.contains("week") {
                score -= 120
            }
            return score
        }) {
            return best
        }

        let shortResetCandidates = candidates.filter { metric in
            guard let resetAt = metric.resetAt else { return false }
            let seconds = resetAt.timeIntervalSince(now)
            return seconds > 0 && seconds <= 8 * 3600
        }
        return shortResetCandidates.count == 1 ? shortResetCandidates[0] : nil
    }

    private func bestMetric(
        from metrics: [QuotaMetric],
        minimumScore: Int = 1,
        scoredBy scorer: (QuotaMetric) -> Int
    ) -> QuotaMetric? {
        var best: (metric: QuotaMetric, score: Int)?
        for metric in metrics {
            let score = scorer(metric)
            guard score >= minimumScore else { continue }
            if best == nil || score > best!.score {
                best = (metric, score)
            }
        }
        return best?.metric
    }

    private func quotaText(_ metric: QuotaMetric) -> String {
        "\(metric.name) \(metric.context) \(metric.detail ?? "")"
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}

struct MetricExtractor {
    let payload: Any

    func metrics() -> [QuotaMetric] {
        var output: [QuotaMetric] = []
        collect(from: payload, path: [], output: &output)
        return output
    }

    private func collect(from value: Any, path: [String], output: inout [QuotaMetric]) {
        if let dict = value as? [String: Any] {
            if let metric = metric(from: dict, path: path), !containsEquivalent(metric, in: output) {
                output.append(metric)
            }
            for key in dict.keys.sorted() {
                guard let child = dict[key] else { continue }
                collect(from: child, path: path + [key], output: &output)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                collect(from: child, path: path + ["\(index)"], output: &output)
            }
        }
    }

    private func metric(from dict: [String: Any], path: [String]) -> QuotaMetric? {
        let fields = normalizedFields(from: dict)
        let context = contextText(path: path, fields: fields)
        let usedPercentCandidate = firstNumber(fields, keys: [
            "usedpercent", "usedpercentage", "usagepercent", "usagepercentage",
            "consumedpercent", "percentused", "utilization"
        ])
        let remainingPercentCandidate = firstNumber(fields, keys: [
            "remainingpercent", "remainingpercentage", "percentremaining",
            "availablepercent", "availablepercentage", "leftpercent", "percentleft"
        ])
        let genericPercent = firstNumber(fields, keys: ["percent", "percentage"])
        let used = firstNumber(fields, keys: ["used", "usage", "consumed", "current"])
        let remaining = firstNumber(fields, keys: ["remaining", "available", "left"])
        let limit = firstNumber(fields, keys: ["limit", "total", "max", "quota", "allowed", "cap"])

        let usedPercent: Double?
        let remainingPercent: Double?
        if let remainingPercentCandidate {
            remainingPercent = normalizePercent(remainingPercentCandidate)
            usedPercent = 1 - remainingPercent!
        } else if let usedPercentCandidate {
            remainingPercent = nil
            usedPercent = normalizePercent(usedPercentCandidate)
        } else if let genericPercent, contextContainsRemaining(context) {
            remainingPercent = normalizePercent(genericPercent)
            usedPercent = 1 - remainingPercent!
        } else if let genericPercent, contextContainsUsed(context) {
            remainingPercent = nil
            usedPercent = normalizePercent(genericPercent)
        } else if let remaining, let limit, limit > 0 {
            remainingPercent = normalizeRatio(remaining, limit: limit)
            usedPercent = 1 - remainingPercent!
        } else if let used, let limit, limit > 0 {
            remainingPercent = nil
            usedPercent = used / limit
        } else {
            remainingPercent = nil
            usedPercent = nil
        }

        guard let usedPercent else { return nil }
        let resetAt = firstDate(fields, keys: [
            "resetat", "resetsat", "resettime", "nextresetat",
            "endsat", "expiresat", "resetsin", "resetin"
        ])
        let name = firstString(fields, keys: [
            "name", "type", "window", "period", "interval", "model",
            "bucket", "label", "limittype", "limitname"
        ])
            ?? readableName(path: path)
        let detail: String?
        if let used, let limit {
            detail = "\(compactNumber(used)) / \(compactNumber(limit))"
        } else if let remaining, let limit {
            detail = "\(compactNumber(remaining)) left of \(compactNumber(limit))"
        } else {
            detail = nil
        }

        return QuotaMetric(
            name: name,
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            resetAt: resetAt,
            detail: detail,
            context: context
        )
    }

    private func containsEquivalent(_ metric: QuotaMetric, in metrics: [QuotaMetric]) -> Bool {
        metrics.contains { existing in
            existing.name == metric.name
                && existing.context == metric.context
                && abs(existing.remainingFraction - metric.remainingFraction) < 0.001
        }
    }

    private func normalizedFields(from dict: [String: Any]) -> [Field] {
        dict.map { key, value in
            Field(originalKey: key, normalizedKey: normalizeKey(key), value: value)
        }
    }

    private func firstNumber(_ fields: [Field], keys: [String]) -> Double? {
        for key in keys {
            guard let field = fields.first(where: { $0.normalizedKey == key }) else { continue }
            if let bool = field.value as? Bool {
                _ = bool
                continue
            }
            if let number = field.value as? NSNumber { return number.doubleValue }
            if let double = field.value as? Double { return double }
            if let int = field.value as? Int { return Double(int) }
            if let string = field.value as? String, let double = Double(string) { return double }
        }
        return nil
    }

    private func firstString(_ fields: [Field], keys: [String]) -> String? {
        for key in keys {
            if let field = fields.first(where: { $0.normalizedKey == key }),
               let string = field.value as? String,
               !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private func firstDate(_ fields: [Field], keys: [String]) -> Date? {
        for key in keys {
            guard let field = fields.first(where: { $0.normalizedKey == key }) else { continue }
            if let string = field.value as? String, let date = Self.parseISODate(string) {
                return date
            }
            if let number = field.value as? NSNumber {
                let seconds = number.doubleValue
                if field.normalizedKey.hasSuffix("in") {
                    return Date().addingTimeInterval(seconds)
                }
                return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
            }
        }
        return nil
    }

    private func normalizePercent(_ value: Double) -> Double {
        min(max(value > 1 ? value / 100 : value, 0), 1)
    }

    private func normalizeRatio(_ value: Double, limit: Double) -> Double {
        min(max(value / limit, 0), 1)
    }

    private func normalizeKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func contextText(path: [String], fields: [Field]) -> String {
        let stringValues = fields.compactMap { $0.value as? String }
        return (path + fields.map(\.originalKey) + stringValues)
            .joined(separator: " ")
            .lowercased()
    }

    private func contextContainsRemaining(_ context: String) -> Bool {
        context.contains("remaining") || context.contains("available") || context.contains("left")
    }

    private func contextContainsUsed(_ context: String) -> Bool {
        context.contains("used")
            || context.contains("consumed")
            || (context.contains("usage") && !context.contains("limit"))
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

    private struct Field {
        let originalKey: String
        let normalizedKey: String
        let value: Any
    }

    /// Some sources (e.g. Claude OAuth usage) emit ISO-8601 timestamps with
    /// fractional seconds — "2026-06-04T11:10:00.973380+00:00" — which a default
    /// `ISO8601DateFormatter` rejects. Try the fractional-seconds variant first,
    /// then fall back to the plain internet date-time format.
    private static let isoFormatters: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractional, plain]
    }()

    static func parseISODate(_ string: String) -> Date? {
        for formatter in isoFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
