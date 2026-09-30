import SwiftUI
import ServiceManagement

struct SettingsTabView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("refreshInterval")   private var refreshInterval: Int    = 300
    @AppStorage("notifyWarning")     private var notifyWarning: Bool     = true
    @AppStorage("notifyActivated")   private var notifyActivated: Bool   = true
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var historyExpanded = false
    @AppStorage("rateLimitGuard")    private var rateLimitGuard: Bool    = true

    @AppStorage("morningPrewarmHour")         private var morningHour: Int         = 6
    @AppStorage("morningPrewarmMinute")       private var morningMinute: Int       = 0
    @AppStorage("morningPrewarmWeekdaysOnly") private var morningWeekdaysOnly: Bool = true
    @AppStorage(QuotaDisplay.colorfulBarsKey) private var colorfulBars: Bool = true

    private let refreshOptions: [(label: String, value: Int)] = [
        ("5m", 300), ("10m", 600), ("15m", 900), ("30m", 1800)
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                settingsHeader

                group("CHECKS") {
                    row(icon: "clock.arrow.2.circlepath", title: "Quota Refresh Interval",
                        subtitle: "Default 5 minutes") {
                        segmentedPicker(
                            options: refreshOptions,
                            selected: $refreshInterval
                        ) { appState.applyRefreshInterval() }
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "shield.lefthalf.filled", title: "Rate-limit Guard",
                        subtitle: "Back off after failures") {
                        Toggle("", isOn: $rateLimitGuard)
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "arrow.clockwise", title: "Manual Refresh",
                        subtitle: "Monitored tools only") {
                        Button(action: { appState.refreshAllActivity() }) {
                            Text("Refresh")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 13)
                                .frame(height: 26)
                                .background(DS.C.surfaceHigh, in: Capsule())
                                .foregroundStyle(DS.C.textSub)
                                .overlay(Capsule().stroke(DS.C.border, lineWidth: 1))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }

                group("DISPLAY") {
                    row(icon: "paintpalette", title: "Colorful Quota Bars",
                        subtitle: colorfulBars ? "Blue → orange at 50% → red at 80% used" : "Single-color bars") {
                        Toggle("", isOn: $colorfulBars)
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                            .accessibilityLabel(Text("Colorful quota bars"))
                    }
                }

                group("MORNING PRE-WARM") {
                    row(icon: "sunrise", title: "Wake & Warm Each Morning",
                        subtitle: "Wakes a sleeping Mac to start your window") {
                        Toggle("", isOn: Binding(
                            get: { appState.morningPrewarmEnabled },
                            set: { appState.setMorningPrewarm($0) }
                        ))
                        .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "clock", title: "Wake Time",
                        subtitle: "Start the window before you sit down") {
                        // Typed by hand (HH:mm). A DS-styled text field instead of
                        // the AppKit stepper DatePicker, which renders as a
                        // clipped dark box in this scaled borderless panel.
                        WakeTimeField(hour: $morningHour, minute: $morningMinute) {
                            appState.morningTimeChanged()
                        }
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "calendar", title: "Weekdays Only",
                        subtitle: "Skip Saturday and Sunday") {
                        Toggle("", isOn: $morningWeekdaysOnly)
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                            .onChange(of: morningWeekdaysOnly) { _, _ in appState.morningTimeChanged() }
                    }

                    if let status = appState.morningStatus {
                        Divider().background(DS.C.border).padding(.leading, 36)
                        HStack(alignment: .top, spacing: DS.Space.sm) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12)).foregroundStyle(DS.C.textSub).frame(width: 20)
                            Text(status)
                                .font(.system(size: 9.5)).foregroundStyle(DS.C.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.sm + 2)
                    }
                }

                group("ALERTS") {
                    row(icon: "bell.badge", title: "Window Expiring Soon",
                        subtitle: "30 min before reset") {
                        Toggle("", isOn: $notifyWarning)
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "checkmark.circle", title: "Window Activated",
                        subtitle: "After warmup succeeds") {
                        Toggle("", isOn: $notifyActivated)
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    }
                }

                group("SYSTEM") {
                    row(icon: "power", title: "Launch at Login",
                        subtitle: "Start with macOS") {
                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                            .onChange(of: launchAtLogin) { _, v in
                                updateLaunchAtLogin(v)
                            }
                    }
                    if let launchAtLoginError {
                        Divider().background(DS.C.border).padding(.leading, 36)
                        Text(launchAtLoginError)
                            .font(.system(size: 9.5))
                            .foregroundStyle(DS.C.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.sm)
                    }
                }

                group("HISTORY") {
                    historyContent
                }

                group("HOW IT WORKS") {
                    transparencyRow(
                        "What QuotaWarmer does",
                        "It watches your own Claude Code and Codex quota windows. Only for tools you switch to Auto-warm, it sends a single minimal \"hi\" through the CLI you're already logged into, the moment a fresh window opens."
                    )
                    Divider().background(DS.C.border).padding(.leading, 36)
                    transparencyRow(
                        "What it never does",
                        "It never bypasses or raises your limits, never shares or uploads your credentials, and never sends anything for tools left on Monitor or Off."
                    )
                    Divider().background(DS.C.border).padding(.leading, 36)
                    transparencyRow(
                        "Is this allowed?",
                        "You're using capacity you already pay for, through the official CLI you already use. Providers may change their APIs at any time; if automated warm-up is ever disallowed, switch any tool to Monitor and QuotaWarmer keeps tracking your quota."
                    )
                }

                group("PRIVACY") {
                    infoRow(
                        title: "Credential access",
                        detail: "Monitored tools only. Claude reads Keychain Claude Code-credentials, env CLAUDE_CODE_OAUTH_TOKEN, or ~/.claude/.credentials.json. Codex reads auth.json or Keychain Codex Auth."
                    )
                    Divider().background(DS.C.border).padding(.leading, 36)
                    infoRow(
                        title: "Logs",
                        detail: "History is mirrored to /tmp/quotawarmer-diagnostics.log. Tokens and authorization headers are redacted and are never written to history or warmup logs."
                    )
                }

                group("ABOUT") {
                    HStack(spacing: DS.Space.md) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(DS.C.accent(.claude))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("QuotaWarmer")
                                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.C.text)
                            Text("Version \(appVersion)  ·  macOS 14+")
                                .font(.system(size: 10)).foregroundStyle(DS.C.textMuted)
                        }
                        Spacer()
                        if appState.updateInfo != nil {
                            Text("update available")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(DS.C.accent(.claude))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(DS.C.accent(.claude).opacity(0.10), in: Capsule())
                                .overlay(Capsule().stroke(DS.C.accent(.claude).opacity(0.20)))
                        }
                    }
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.md)

                    Divider().background(DS.C.border).padding(.leading, DS.Space.md)

                    if let update = appState.updateInfo {
                        Button(action: { NSWorkspace.shared.open(update.htmlURL) }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill").font(.system(size: 11))
                                Text("Download v\(update.version)").font(.system(size: 11))
                            }
                            .foregroundStyle(DS.C.accent(.claude))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.md)
                        }
                        .buttonStyle(.plain)
                        Divider().background(DS.C.border).padding(.leading, DS.Space.md)
                    } else {
                        row(icon: "arrow.clockwise.circle", title: "Check for Updates",
                            subtitle: "Check GitHub for the latest release") {
                            Button(action: { Task { await appState.checkForAppUpdate() } }) {
                                Text("Check")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 13)
                                    .frame(height: 26)
                                    .background(DS.C.surfaceHigh, in: Capsule())
                                    .foregroundStyle(DS.C.textSub)
                                    .overlay(Capsule().stroke(DS.C.border, lineWidth: 1))
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                        Divider().background(DS.C.border).padding(.leading, 36)
                    }

                    Button(action: { NSApplication.shared.terminate(nil) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle").font(.system(size: 11))
                            Text("Quit QuotaWarmer").font(.system(size: 11))
                        }
                        .foregroundStyle(DS.C.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.md)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, DS.Page.bottom)
        }
        .background(DS.C.bg)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let build = info?["CFBundleVersion"] as? String, build != version {
            return "\(version) (\(build))"
        }
        return version
    }

    // MARK: - History

    /// Collapsible list of the latest events (moved here from the overview so
    /// the main panel stays focused on the live quota windows).
    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { historyExpanded.toggle() }) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DS.C.textSub)
                        .frame(width: 20)
                    Text("Recent Events")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DS.C.text)
                    Spacer()
                    Text("\(appState.history.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.C.textMuted)
                    Image(systemName: historyExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.C.textMuted)
                }
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.sm + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text(historyExpanded ? "Collapse history" : "Expand history"))

            if historyExpanded {
                Divider().background(DS.C.border).padding(.leading, 36)
                if appState.history.isEmpty {
                    Text("No events yet")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.C.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.lg)
                } else {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(appState.history.prefix(10)) { event in
                            HistoryRow(event: event)
                        }
                    }
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.sm + 2)
                }
            }
        }
    }

    // MARK: - Layout helpers

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Launch at Login could not be changed: \(error.localizedDescription)"
        }

        let actual = SMAppService.mainApp.status == .enabled
        UserDefaults.standard.set(actual, forKey: "launchAtLogin")
        if launchAtLogin != actual {
            launchAtLogin = actual
        }
    }

    private var settingsHeader: some View {
        PanelHeader(title: "Settings") { EmptyView() }
            .padding(.horizontal, DS.Page.side)
            .padding(.top, DS.Page.top)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .dsSectionLabel()
                .padding(.horizontal, DS.Page.side + 2)
                .padding(.top, DS.Space.md)
                .padding(.bottom, DS.Space.xs + 2)

            VStack(spacing: 0) {
                content()
            }
            .dsCard()
            .padding(.horizontal, DS.Page.side)
        }
    }

    private func row<Control: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.C.textSub)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.C.text)
                    .lineLimit(1)
                    .fixedSize()
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.C.textMuted)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm - 1)
    }

    private func privacyLine(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.C.text)
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(DS.C.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Full-width, always-visible explanatory row for the HOW IT WORKS group.
    private func transparencyRow(_ title: String, _ detail: String) -> some View {
        privacyLine(title, detail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm + 2)
    }

    private func infoRow(title: String, detail: String) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(DS.C.textSub)
                .frame(width: 20)
                .help(detail)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.C.text)
            Spacer()
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm + 2)
    }

    private func segmentedPicker(
        options: [(label: String, value: Int)],
        selected: Binding<Int>,
        onChange: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let isSelected = selected.wrappedValue == opt.value
                Button(action: { selected.wrappedValue = opt.value; onChange() }) {
                    Text(opt.label)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(
                            isSelected ? DS.C.surface : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isSelected ? DS.C.border : Color.clear, lineWidth: 1)
                        )
                        .foregroundStyle(isSelected ? DS.C.text : DS.C.textMuted)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(2)
        .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Hand-typed HH:mm field drawn with DS tokens so it matches both themes.
/// Commits on Return or when focus leaves; input is parsed by `TimeInput`
/// (`6`, `630`, `6:30`, `06.30` …). Invalid text is rejected and the field
/// snaps back to the last valid time, so a typo can never schedule a bogus wake.
struct WakeTimeField: View {
    @Binding var hour: Int
    @Binding var minute: Int
    let onChange: () -> Void

    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("HH:mm", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .foregroundStyle(DS.C.text)
            .focused($focused)
            .frame(width: 52, height: 26)
            .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(invalid ? DS.C.red : (focused ? DS.C.blue.opacity(0.6) : DS.C.border), lineWidth: 1)
            )
            .onAppear { draft = TimeInput.text(hour: hour, minute: minute) }
            .onChange(of: hour) { _, _ in if !focused { resetDraft() } }
            .onChange(of: minute) { _, _ in if !focused { resetDraft() } }
            // Keep the red "rejected" border until the user types something new
            // (the snap-back to the valid time must not clear it).
            .onChange(of: draft) { _, text in
                if text != TimeInput.text(hour: hour, minute: minute) { invalid = false }
            }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .help("Type a time, e.g. 06:00, 6:30 or 0715, then press Return.")
            .accessibilityLabel(Text("Wake time"))
    }

    private func commit() {
        guard let parsed = TimeInput.parse(draft) else {
            invalid = true
            resetDraft()
            return
        }
        let changed = parsed.hour != hour || parsed.minute != minute
        invalid = false
        hour = parsed.hour
        minute = parsed.minute
        resetDraft()
        if changed { onChange() }
    }

    private func resetDraft() {
        let text = TimeInput.text(hour: hour, minute: minute)
        if draft != text { draft = text }
    }
}
