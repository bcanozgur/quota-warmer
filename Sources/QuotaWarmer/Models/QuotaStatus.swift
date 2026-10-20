import Foundation

/// The live quota as a file other tools can read:
/// `~/Library/Application Support/QuotaWarmer/status.json`, rewritten after
/// every successful quota fetch. `scripts/quotawarmer-statusline.sh` turns it
/// into a one-line status for Claude Code, tmux or starship.
///
/// This is a public format: bump `schemaVersion` on any breaking change
/// (renamed or removed field, changed meaning); adding a field is not breaking.
/// Never put tokens, account ids from the provider, or command output here.
struct QuotaStatusFile: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let providers: [QuotaStatusProvider]
}

/// One watched account. `freshness` is as of `generatedAt`; consumers should
/// recompute it from `fetchedAt` (fresh ≤ 5 min, stale ≤ 30 min, else expired),
/// because the file is only rewritten when some fetch succeeds.
struct QuotaStatusProvider: Codable, Equatable {
    /// `ProviderID.storageKey`: `claude`, `codex`, `claude.work`.
    let id: String
    let tool: String
    let account: String
    /// Display label: `Claude`, `Claude · Work`.
    let name: String
    /// `off`, `monitor` or `autoWarm`.
    let mode: String
    /// `remaining` or `used`: how the user chose to see this account's percent.
    let displayMode: String
    /// Pinned to the menu bar.
    let pinned: Bool
    /// nil until the first successful fetch since launch.
    let fetchedAt: Date?
    let freshness: String
    let session: QuotaStatusWindow?
    let weekly: QuotaStatusWindow?
}

struct QuotaStatusWindow: Codable, Equatable {
    /// Whole percents, rounded as the app shows them; they always sum to 100.
    let usedPercent: Int
    let remainingPercent: Int
    let resetAt: Date?
    /// Not started yet: quota is full and any `resetAt` is only a projection.
    let idle: Bool
    /// Just rolled over and the provider still reports the old window's usage;
    /// show the countdown, not the percent.
    let settling: Bool
}

enum QuotaStatusExport {
    struct Entry {
        let provider: ProviderID
        let mode: ToolMode
        let displayMode: QuotaDisplayMode
        let pinned: Bool
        let snapshot: QuotaSnapshot?
    }

    static func make(_ entries: [Entry], now: Date = Date()) -> QuotaStatusFile {
        QuotaStatusFile(
            schemaVersion: QuotaStatusFile.schemaVersion,
            generatedAt: now,
            providers: entries.map { provider($0, now: now) }
        )
    }

    static func provider(_ entry: Entry, now: Date) -> QuotaStatusProvider {
        let snapshot = entry.snapshot
        let settling = snapshot?.isUnsettledRolloverReading(windowDuration: entry.provider.windowDuration, now: now) ?? false
        return QuotaStatusProvider(
            id: entry.provider.storageKey,
            tool: entry.provider.kind.rawValue,
            account: entry.provider.accountID,
            name: entry.provider.shortName,
            mode: entry.mode.rawValue,
            displayMode: entry.displayMode.rawValue,
            pinned: entry.pinned,
            fetchedAt: snapshot?.fetchedAt,
            freshness: (snapshot?.freshness(now: now) ?? .unknown).rawValue,
            session: snapshot?.fiveHour.map { window($0, settling: settling) },
            weekly: snapshot?.weekly.map { window($0, settling: false) }
        )
    }

    private static func window(_ metric: QuotaMetric, settling: Bool) -> QuotaStatusWindow {
        let remaining = QuotaDisplay.remainingPercent(remainingFraction: metric.remainingFraction)
        return QuotaStatusWindow(
            usedPercent: 100 - remaining,
            remainingPercent: remaining,
            resetAt: metric.resetAt,
            idle: metric.isIdle,
            settling: settling
        )
    }

    /// Stable, human-readable JSON: sorted keys, ISO 8601 UTC dates.
    static func encode(_ file: QuotaStatusFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(file)
        data.append(0x0A)
        return data
    }

    static func decode(_ data: Data) throws -> QuotaStatusFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QuotaStatusFile.self, from: data)
    }

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("QuotaWarmer/status.json")
    }

    private static let queue = DispatchQueue(label: "com.quotawarmer.status-export", qos: .utility)

    /// Encodes now and writes off the main actor. The write is atomic (temp file
    /// + rename), so a reader never sees a half-written file.
    static func write(_ file: QuotaStatusFile, to url: URL = defaultURL) {
        guard let data = try? encode(file) else { return }
        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                DiagnosticLogger.append("status_export_write_failed")
            }
        }
    }
}
