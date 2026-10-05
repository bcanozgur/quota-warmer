import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from going back to sleep while a scheduled quota check or
/// warm-up runs. A `pmset` wake on battery with the lid closed is only a
/// DarkWake that lasts a few seconds; without an assertion the system re-sleeps
/// mid-command and the claim lands whenever the next wake happens.
///
/// Several assertion types are taken because they cover different states:
/// `PreventUserIdleSystemSleep` for a normal wake, `PreventSystemSleep` on AC,
/// and `BackgroundTask` (the type `dasd` uses) for DarkWake. Each one carries a
/// timeout, so a lost `release()` can never keep the Mac awake indefinitely.
final class SleepGuard {
    private static let assertionTypes = [
        kIOPMAssertionTypePreventUserIdleSystemSleep as String,
        kIOPMAssertionTypePreventSystemSleep as String,
        "BackgroundTask",
    ]

    private let lock = NSLock()
    private var ids: [IOPMAssertionID] = []

    /// Takes the assertions immediately. Safe to call from any thread.
    init(reason: String, timeout: TimeInterval = 180) {
        var taken: [String] = []
        var failed: [String] = []
        for type in Self.assertionTypes {
            let properties: [String: Any] = [
                kIOPMAssertionTypeKey: type,
                kIOPMAssertionNameKey: "QuotaWarmer: \(reason)",
                kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
                kIOPMAssertionTimeoutKey: timeout,
                kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
            ]
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
            if result == kIOReturnSuccess {
                ids.append(id)
                taken.append(type)
            } else {
                failed.append("\(type)=\(String(format: "0x%x", result))")
            }
        }
        DiagnosticLogger.append(
            "sleep_guard_acquired reason=\(reason) taken=\(taken.joined(separator: ",")) failed=\(failed.joined(separator: ",")) \(Self.powerContext())"
        )
    }

    func release() {
        lock.lock()
        let toRelease = ids
        ids.removeAll()
        lock.unlock()
        toRelease.forEach { IOPMAssertionRelease($0) }
    }

    deinit { release() }

    private static func powerContext() -> String {
        "ac=\(WakeScheduler.isOnACPower() ? 1 : 0)"
    }
}
