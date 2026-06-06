import Foundation

enum QuotaFreshness: String {
    case unknown
    case fresh
    case stale
    case expired

    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .fresh: return "fresh"
        case .stale: return "stale"
        case .expired: return "expired"
        }
    }
}

enum SourceHealth: String {
    case unknown
    case healthy
    case stale
    case unavailable
    case authFailure
    case rateLimited

    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .healthy: return "healthy"
        case .stale: return "stale"
        case .unavailable: return "unavailable"
        case .authFailure: return "auth failure"
        case .rateLimited: return "rate limited"
        }
    }
}

enum AuthStatus: String {
    case unknown
    case available
    case missing
    case failed

    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .available: return "available"
        case .missing: return "missing"
        case .failed: return "failed"
        }
    }
}

enum HistoryKind: String {
    case quotaFetch
    case resetDetected
    case autoWarmup
    case manualWarmup
    case authFailure
    case rateLimit
    case pollingError
    case updateCheck
}

enum ScheduledWarmupSkipReason: String {
    case alreadySucceeded
    case beforeScheduledTime
    case outsideCatchUpHorizon
    case activeWindowInProgress
    case userAlreadyActive
}

enum ScheduledWarmupDecision {
    case run(caughtUp: Bool)
    case skip(ScheduledWarmupSkipReason)

    var shouldRun: Bool {
        if case .run = self { return true }
        return false
    }

    var caughtUp: Bool {
        if case .run(let caughtUp) = self { return caughtUp }
        return false
    }
}

struct MorningWarmupPolicy {
    static let catchUpLatenessThreshold: TimeInterval = 15 * 60

    static func resolvedLastSuccessfulDay(
        perToolDay: String?,
        legacyDay: String?,
        currentDay: String
    ) -> String? {
        if let perToolDay {
            return perToolDay
        }
        return legacyDay == currentDay ? legacyDay : nil
    }

    static func decision(
        now: Date,
        scheduledAt: Date,
        dayKey: String,
        lastSuccessfulDay: String?,
        lastActivity: Date?,
        activeWindowStartedAt: Date?,
        windowDuration: TimeInterval,
        catchUpHorizon: TimeInterval? = nil,
        catchUpLatenessThreshold: TimeInterval = Self.catchUpLatenessThreshold
    ) -> ScheduledWarmupDecision {
        if lastSuccessfulDay == dayKey {
            return .skip(.alreadySucceeded)
        }

        let lateness = now.timeIntervalSince(scheduledAt)
        guard lateness >= 0 else {
            return .skip(.beforeScheduledTime)
        }

        let horizon = catchUpHorizon ?? windowDuration
        guard lateness <= horizon else {
            return .skip(.outsideCatchUpHorizon)
        }

        if let activeWindowStartedAt,
           activeWindowStartedAt <= now,
           activeWindowStartedAt.addingTimeInterval(windowDuration) > now {
            return .skip(.activeWindowInProgress)
        }

        if let lastActivity, lastActivity >= scheduledAt {
            return .skip(.userAlreadyActive)
        }

        return .run(caughtUp: lateness > catchUpLatenessThreshold)
    }
}

struct HistoryEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let tool: ToolID?
    let kind: HistoryKind
    let title: String
    let detail: String
}

struct QuotaMetric: Identifiable {
    let id = UUID()
    let name: String
    let usedPercent: Double
    let remainingPercent: Double?
    let resetAt: Date?
    let detail: String?
    let context: String

    init(
        name: String,
        usedPercent: Double,
        remainingPercent: Double?,
        resetAt: Date?,
        detail: String?,
        context: String = ""
    ) {
        self.name = name
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.detail = detail
        self.context = context
    }

    var clampedUsed: Double {
        min(max(usedPercent, 0), 1)
    }

    var remainingFraction: Double {
        if let remainingPercent {
            return min(max(remainingPercent, 0), 1)
        }
        return min(max(1 - clampedUsed, 0), 1)
    }

    var isIdleFiveHourWindow: Bool {
        resetAt == nil && context.contains("idle") && name.lowercased().contains("5h")
    }
}

struct QuotaSnapshot {
    let tool: ToolID
    let fetchedAt: Date
    let primarySource: String
    let corroboratingSource: String?
    let fiveHour: QuotaMetric?
    let weekly: QuotaMetric?
    let extras: [QuotaMetric]
    let rawWindowKey: String
    let message: String?

    func freshness(now: Date = Date()) -> QuotaFreshness {
        let age = now.timeIntervalSince(fetchedAt)
        if age <= 5 * 60 { return .fresh }
        if age <= 30 * 60 { return .stale }
        return .expired
    }

    func canAutoWarm(
        now: Date = Date(),
        windowDuration: TimeInterval,
        remainingThreshold: Double = 0.95,
        freshWindowGrace: TimeInterval = 10 * 60
    ) -> Bool {
        guard freshness(now: now) == .fresh,
              let metric = fiveHour,
              let resetAt = metric.resetAt,
              metric.remainingFraction >= remainingThreshold else {
            return false
        }

        let inferredWindowStart = resetAt.addingTimeInterval(-windowDuration)
        let windowAge = now.timeIntervalSince(inferredWindowStart)
        return windowAge >= 0 && windowAge <= freshWindowGrace
    }

    func isClaimableAutoWindow(previousFetchedAt: Date?, now: Date = Date()) -> Bool {
        guard freshness(now: now) == .fresh else { return false }
        guard let previousFetchedAt else { return true }
        return fetchedAt > previousFetchedAt
    }
}

struct Credential {
    let accessToken: String
    let refreshToken: String?
    let accountID: String?
    let source: String
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

enum CredentialError: LocalizedError {
    case missing(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .missing(let provider): return "\(provider) credentials not found"
        case .invalid(let provider): return "\(provider) credentials are invalid"
        }
    }
}

enum QuotaProviderError: LocalizedError {
    case missingCredentials(String)
    case authFailure(String)
    case rateLimited(String, retryAfter: TimeInterval?)
    case unavailable(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let msg): return msg
        case .authFailure(let msg): return msg
        case .rateLimited(let msg, _): return msg
        case .unavailable(let msg): return msg
        case .malformed(let msg): return msg
        }
    }
}
