import Foundation
import AppKit

class Scheduler {
    var onFire: ((ToolID) -> Void)?

    private var timers: [ToolID: DispatchSourceTimer] = [:]
    private let queue = DispatchQueue(label: "com.quotawarmer.scheduler")
    private var observers: [NSObjectProtocol] = []

    init() {
        let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onFire.map { fire in
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

        let delay = max(fireDate.timeIntervalSinceNow, 0)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.onFire?(tool)
            }
        }
        timers[tool] = timer
        timer.resume()
    }

    func invalidateAll() {
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
    }

    func invalidate(tool: ToolID) { cancelTimer(for: tool) }

    private func cancelTimer(for tool: ToolID) {
        timers[tool]?.cancel()
        timers.removeValue(forKey: tool)
    }
}
