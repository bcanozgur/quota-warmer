import Foundation

enum DebugLevel: Int, CaseIterable {
    case off = 0
    case normal = 1
    case verbose = 2

    var title: String {
        switch self {
        case .off:     return "Off"
        case .normal:  return "Normal"
        case .verbose: return "Verbose"
        }
    }

    static var current: DebugLevel {
        get {
            let raw = UserDefaults.standard.object(forKey: "debugLevel") as? Int ?? DebugLevel.normal.rawValue
            return DebugLevel(rawValue: raw) ?? .normal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "debugLevel") }
    }
}

enum DiagnosticLogger {
    /// `~/Library/Logs/QuotaWarmer/` — per-user, not world-readable, survives reboot.
    static let directory: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent("Logs/QuotaWarmer", isDirectory: true)
    }()
    static let fileURL = directory.appendingPathComponent("diagnostics.log")
    private static let writeLock = NSLock()
    private static var directoryReady = false

    /// Rotation: `diagnostics.log` plus `diagnostics.1.log` … up to `maxFiles` files.
    static let maxBytes: UInt64 = 2 * 1024 * 1024
    static let maxFiles = 3

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Newest first: the live file, then the rotated ones that exist.
    static var logFiles: [URL] { logFiles(in: directory) }

    static func logFiles(in directory: URL, maxFiles: Int = DiagnosticLogger.maxFiles) -> [URL] {
        (0..<maxFiles).map { rotatedURL($0, in: directory) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func rotatedURL(_ index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent(index == 0 ? "diagnostics.log" : "diagnostics.\(index).log")
    }

    static func appendHistory(_ event: HistoryEvent) {
        let tool = event.tool?.rawValue ?? "app"
        append("history tool=\(tool) kind=\(event.kind.rawValue) title=\(event.title) detail=\(event.detail)")
    }

    static func append(_ message: String) {
        guard DebugLevel.current != .off else { return }
        let line = "[\(formatter.string(from: Date()))] \(redacted(message))\n"
        guard let data = line.data(using: .utf8) else { return }

        // Callers run on the main actor and on detached tasks. Without this,
        // two concurrent seek-to-end + write pairs land on the same offset and
        // one line silently overwrites the other.
        writeLock.lock()
        defer { writeLock.unlock() }
        if !directoryReady {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            directoryReady = true
        }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.write(contentsOf: data)
            try? handle.close()
            if size + UInt64(data.count) > maxBytes { rotate(in: directory, maxFiles: maxFiles) }
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    /// Shifts `diagnostics.N.log` → `N+1`, dropping the oldest, and starts a
    /// fresh live file. Caller holds `writeLock` (or owns `directory`).
    static func rotate(in directory: URL, maxFiles: Int) {
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL(maxFiles - 1, in: directory))
        for index in stride(from: maxFiles - 2, through: 0, by: -1) {
            let source = rotatedURL(index, in: directory)
            if fm.fileExists(atPath: source.path) {
                try? fm.moveItem(at: source, to: rotatedURL(index + 1, in: directory))
            }
        }
    }

    static func redacted(_ text: String) -> String {
        var output = text
        let patterns = [
            #"sk-[A-Za-z0-9._-]{12,}"#,
            #"Bearer\s+[A-Za-z0-9._-]{12,}"#,
            #"Authorization[:=]\s*[A-Za-z0-9._\-\s]{12,}"#
        ]

        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: .regularExpression
            )
        }
        return output
    }
}
