import Foundation
import AppKit

class Scheduler {
    var onFire: ((ToolID) -> Void)?
    /// Called once each time the system wakes from sleep, before the per-tool
    /// fires. Used for morning pre-warm bookkeeping / catch-up.
    var onWake: (() -> Void)?

    private var timers: [ToolID: DispatchSourceTimer] = [:]
    private var morningTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.quotawarmer.scheduler")
    private var observers: [NSObjectProtocol] = []

    init() {
        let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onWake?()
            if let fire = self.onFire {
                ToolID.allCases.forEach { fire($0) }
            }
        }
        observers.append(wakeObserver)
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        invalidateAll()
    }

    func schedule(tool: ToolID, at fireDate: Date) {
        cancelTimer(for: tool)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(wallDeadline: Self.wallDeadline(for: fireDate), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.onFire?(tool)
            }
        }
        timers[tool] = timer
        timer.resume()
    }

    /// One-shot wall-clock timer for the morning pre-warm. The handler gets a
    /// `SleepGuard` that was taken on the timer queue the instant the timer
    /// fired — before any hop to the main actor — because a scheduled DarkWake
    /// re-sleeps within seconds. The handler owns it and must `release()` it.
    func scheduleMorning(at fireDate: Date, handler: @escaping (SleepGuard) -> Void) {
        morningTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(wallDeadline: Self.wallDeadline(for: fireDate), leeway: .milliseconds(500))
        timer.setEventHandler {
            let guardToken = SleepGuard(reason: "morning")
            DispatchQueue.main.async { handler(guardToken) }
        }
        morningTimer = timer
        timer.resume()
    }

    func cancelMorning() {
        morningTimer?.cancel()
        morningTimer = nil
    }

    func invalidateAll() {
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
    }

    /// Wall-clock deadline: unlike `DispatchTime` (mach absolute time, which
    /// stops while the Mac sleeps), it fires as soon as the Mac wakes past the
    /// target — including a short DarkWake that posts no `didWakeNotification`.
    private static func wallDeadline(for fireDate: Date) -> DispatchWallTime {
        let interval = max(fireDate.timeIntervalSince1970, Date().timeIntervalSince1970)
        let seconds = floor(interval)
        let nanos = Int((interval - seconds) * 1_000_000_000)
        return DispatchWallTime(timespec: timespec(tv_sec: Int(seconds), tv_nsec: nanos))
    }

    func invalidate(tool: ToolID) { cancelTimer(for: tool) }

    private func cancelTimer(for tool: ToolID) {
        timers[tool]?.cancel()
        timers.removeValue(forKey: tool)
    }
}
