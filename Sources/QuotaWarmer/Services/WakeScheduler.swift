import Foundation

/// Manages a daily macOS scheduled wake (`pmset repeat wakeorpoweron`) so a
/// sleeping Mac wakes in time to start a fresh quota window in the morning —
/// even with the lid closed — and the existing warm-on-wake path can fire.
///
/// Setting the system power schedule needs root, obtained once through a single
/// `osascript` "with administrator privileges" prompt (no persistent helper).
/// Reliable on AC power; closed-lid + battery is best-effort by macOS design, so
/// callers should surface `isOnACPower()` to the user.
struct WakeScheduler {

    enum WakeDays {
        case weekdays   // Mon–Fri
        case everyday

        /// pmset weekday tokens (M Tu W R F Sa U).
        var pmsetToken: String {
            switch self {
            case .weekdays: return "MTWRF"
            case .everyday: return "MTWRFSU"
            }
        }

        var humanLabel: String {
            switch self {
            case .weekdays: return "weekdays"
            case .everyday: return "every day"
            }
        }
    }

    struct ScheduleResult {
        let success: Bool
        let message: String
    }

    /// True when the Mac is on AC power (or has no battery). Used to warn that a
    /// closed-lid + battery scheduled wake may be skipped. Defaults to true when
    /// the state can't be read, to avoid over-warning.
    static func isOnACPower() -> Bool {
        guard let out = run("/usr/bin/pmset", ["-g", "batt"]) else { return true }
        return out.contains("AC Power")
    }

    /// Installs/updates the daily repeating wake. Shows one macOS admin dialog.
    func apply(hour: Int, minute: Int, days: WakeDays) async -> ScheduleResult {
        let time = Self.timeString(hour: hour, minute: minute)
        let command = "/usr/bin/pmset repeat wakeorpoweron \(days.pmsetToken) \(time)"
        return await runPrivileged(
            command,
            successMessage: "Mac will wake at \(Self.displayTime(hour: hour, minute: minute)) \(days.humanLabel)."
        )
    }

    /// Cancels any repeating wake schedule. Shows one admin dialog.
    func cancel() async -> ScheduleResult {
        await runPrivileged(
            "/usr/bin/pmset repeat cancel",
            successMessage: "Scheduled morning wake cancelled."
        )
    }

    /// Reads the active repeating power event, if any (no admin needed).
    /// Best-effort, used to detect a conflicting pre-existing schedule.
    func repeatingScheduleLine() -> String? {
        guard let out = Self.run("/usr/bin/pmset", ["-g", "sched"]) else { return nil }
        return out
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                let l = line.lowercased()
                return l.contains("wake") || l.contains("poweron")
            }
    }

    // MARK: - Internals

    private func runPrivileged(_ shellCommand: String, successMessage: String) async -> ScheduleResult {
        // shellCommand is fully app-constructed (no user free-text), but escape
        // quotes defensively for the AppleScript string literal.
        let escaped = shellCommand.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", appleScript]
                let errPipe = Pipe()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: ScheduleResult(success: true, message: successMessage))
                        return
                    }
                    let errText = String(
                        data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let lower = errText.lowercased()
                    let message: String
                    if lower.contains("-128") || lower.contains("cancel") {
                        message = "Admin permission was cancelled — morning wake not changed."
                    } else {
                        message = errText.isEmpty ? "Could not update the wake schedule." : errText
                    }
                    continuation.resume(returning: ScheduleResult(success: false, message: message))
                } catch {
                    continuation.resume(returning: ScheduleResult(success: false, message: "Could not run pmset."))
                }
            }
        }
    }

    private static func timeString(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d:00", clampHour(hour), clampMinute(minute))
    }

    private static func displayTime(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", clampHour(hour), clampMinute(minute))
    }

    private static func clampHour(_ h: Int) -> Int { min(max(h, 0), 23) }
    private static func clampMinute(_ m: Int) -> Int { min(max(m, 0), 59) }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
