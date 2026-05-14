import Foundation
import Combine

struct WarmupLog: Identifiable {
    let id        = UUID()
    let timestamp: Date
    let command:   String
    let output:    String
}

// MARK: - ToolState

@MainActor
class ToolState: ObservableObject {
    let tool: ToolID

    // Raw data from scanner / warmup
    @Published var lastActivity:   Date?       // latest message ever (display only)
    @Published var windowStart:    Date?       // first msg of current 5h window (scheduling anchor)
    @Published var lastWarmup:     Date?       // last time WE triggered
    @Published var isWarming:      Bool = false
    @Published var errorMessage:   String?
    @Published var weeklyActivity: [DayActivity] = []
    @Published var warmupLogs:     [WarmupLog] = []
    @Published var isLogExpanded:  Bool = false
    @Published var autoWarm:       Bool {
        didSet { UserDefaults.standard.set(autoWarm, forKey: "autoWarm.\(tool.rawValue)") }
    }

    init(tool: ToolID) {
        self.tool     = tool
        self.autoWarm = UserDefaults.standard.object(forKey: "autoWarm.\(tool.rawValue)") as? Bool ?? true
        if let s = UserDefaults.standard.string(forKey: "lastWarmup.\(tool.rawValue)"),
           let d = ISO8601DateFormatter().date(from: s) { self.lastWarmup = d }
    }

    // MARK: Derived — all anchored to windowStart

    /// Window expires at windowStart + 5h. nil when window is not active.
    var windowExpires: Date? {
        windowStart.map { $0.addingTimeInterval(tool.windowDuration) }
    }

    /// 0.0 (just started) → 1.0 (expired). 0 when no active window.
    var windowProgress: Double {
        guard let start = windowStart else { return 0 }
        return min(Date().timeIntervalSince(start) / tool.windowDuration, 1.0)
    }

    /// Seconds until window expires. nil when window expired or never started.
    var timeUntilReset: TimeInterval? {
        guard let exp = windowExpires else { return nil }
        let r = exp.timeIntervalSinceNow
        return r > 0 ? r : nil
    }

    /// true when there's an active (not-yet-expired) window.
    var isWindowActive: Bool { timeUntilReset != nil }

    /// Window expired and needs re-triggering (or was never started).
    var isWindowExpired: Bool { !isWindowActive }

    // MARK: Persist

    func persistWarmup(_ date: Date) {
        lastWarmup = date
        UserDefaults.standard.set(ISO8601DateFormatter().string(from: date), forKey: "lastWarmup.\(tool.rawValue)")
    }
}

// MARK: - AppState

@MainActor
class AppState: ObservableObject {
    @Published var selectedTool:   ToolID = .claude
    @Published var showOnboarding: Bool   = false
    @Published var isRefreshing:   Bool   = false
    @Published var updateInfo:     ReleaseInfo?
    @Published private(set) var toolStates: [ToolID: ToolState]

    private let scanner       = ActivityScanner()
    private let runner        = WarmupRunner()
    private let scheduler     = Scheduler()
    private let notifications = NotificationManager.shared
    private let updateChecker = UpdateChecker()

    init() {
        var states: [ToolID: ToolState] = [:]
        for tool in ToolID.allCases { states[tool] = ToolState(tool: tool) }
        toolStates = states

        scheduler.onFire = { [weak self] tool in
            Task { @MainActor [weak self] in
                guard let self, self.state(for: tool).autoWarm else { return }
                await self.triggerWarmup(tool: tool)
            }
        }

        refreshAllActivity()
        startUIRefreshTimer()
        Task { await checkOnboarding() }
        Task { await checkForAppUpdate() }
    }

    // MARK: - Public API

    /// User pressed Activate (or force-trigger).
    func activate(_ tool: ToolID) {
        Task { await triggerWarmup(tool: tool) }
    }

    /// Refresh scanner data and re-arm scheduler.
    func refreshAllActivity() {
        isRefreshing = true
        for tool in ToolID.allCases {
            let st = toolStates[tool]!
            st.lastActivity  = scanner.lastActivity(for: tool)

            // windowStart from scanner (actual first msg in current window)
            let scannedStart = scanner.windowStartTime(for: tool)

            // If we have a persisted warmup newer than scanner result, use it
            if let warmup = st.lastWarmup {
                let warmupIsInWindow = Date().timeIntervalSince(warmup) < tool.windowDuration
                if warmupIsInWindow {
                    // Our warmup is more recent → use the later of scanner vs warmup as window start
                    if let scanned = scannedStart {
                        // The window that includes our warmup starts at the earliest of the two
                        st.windowStart = min(scanned, warmup)
                    } else {
                        st.windowStart = warmup
                    }
                } else {
                    st.windowStart = scannedStart
                }
            } else {
                st.windowStart = scannedStart
            }

            st.weeklyActivity = scanner.weeklyActivity(for: tool)
            reschedule(tool: tool)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.isRefreshing = false
        }
    }

    func state(for tool: ToolID) -> ToolState { toolStates[tool]! }

    // MARK: - Private

    private func triggerWarmup(tool: ToolID) async {
        let st = state(for: tool)
        st.isWarming    = true
        st.errorMessage = nil
        notifications.cancelAll(for: tool)

        do {
            let result = try await runner.warmup(tool)

            let entry = WarmupLog(timestamp: result.date, command: tool.warmupCommand, output: result.output)
            st.warmupLogs.insert(entry, at: 0)
            if st.warmupLogs.count > 20 { st.warmupLogs.removeLast() }

            st.persistWarmup(result.date)
            st.lastActivity = result.date
            // Our trigger IS the window start of the new window
            st.windowStart  = result.date
            st.weeklyActivity = scanner.weeklyActivity(for: tool)

            // Schedule next auto-trigger at new window expiry
            let expiresAt = result.date.addingTimeInterval(tool.windowDuration)
            scheduler.schedule(tool: tool, at: expiresAt)
            notifications.scheduleWindowWarning(for: tool, expiresAt: expiresAt)
            notifications.notifyActivated(tool: tool)
        } catch {
            st.errorMessage = error.localizedDescription
        }
        st.isWarming = false
    }

    private func reschedule(tool: ToolID) {
        let st = state(for: tool)
        guard st.autoWarm else { scheduler.invalidate(tool: tool); return }

        if let expires = st.windowExpires, expires > Date() {
            // Window still active — schedule trigger at its expiry
            scheduler.schedule(tool: tool, at: expires)
            notifications.scheduleWindowWarning(for: tool, expiresAt: expires)
        }
        // If window already expired: don't auto-trigger on startup; wait for user or next event
    }

    func checkForAppUpdate() async {
        updateInfo = await updateChecker.checkForUpdate()
    }

    private func checkOnboarding() async {
        var anyMissing = false
        for tool in ToolID.allCases {
            if await runner.cliMissing(tool) { anyMissing = true }
        }
        if anyMissing && !UserDefaults.standard.bool(forKey: "onboardingDismissed") {
            showOnboarding = true
        }
    }

    private func startUIRefreshTimer() {
        let interval = TimeInterval(UserDefaults.standard.integer(forKey: "refreshInterval").nonZero ?? 30)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.toolStates.values.forEach { $0.objectWillChange.send() }
            }
        }
    }

    private var refreshTimer: Timer?

    func applyRefreshInterval() {
        startUIRefreshTimer()
    }
}
