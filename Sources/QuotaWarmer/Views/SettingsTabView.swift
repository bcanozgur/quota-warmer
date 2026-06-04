import SwiftUI
import ServiceManagement

struct SettingsTabView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("refreshInterval")   private var refreshInterval: Int    = 300
    @AppStorage("notifyWarning")     private var notifyWarning: Bool     = true
    @AppStorage("notifyActivated")   private var notifyActivated: Bool   = true
    @AppStorage("launchAtLogin")     private var launchAtLogin: Bool     = false
    @AppStorage("rateLimitGuard")    private var rateLimitGuard: Bool    = true

    @AppStorage("morningPrewarmHour")         private var morningHour: Int         = 6
    @AppStorage("morningPrewarmMinute")       private var morningMinute: Int       = 0
    @AppStorage("morningPrewarmWeekdaysOnly") private var morningWeekdaysOnly: Bool = true

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
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.accent(.claude))
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "arrow.clockwise", title: "Manual Refresh",
                        subtitle: "Active tools only") {
                        Button(action: { appState.refreshAllActivity() }) {
                            Text("Refresh")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 11)
                                .frame(height: 26)
                                .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(DS.C.text)
                                .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }

                group("MORNING PRE-WARM") {
                    row(icon: "sunrise", title: "Wake & Warm Each Morning",
                        subtitle: "Wakes a sleeping Mac to start your window") {
                        Toggle("", isOn: Binding(
                            get: { appState.morningPrewarmEnabled },
                            set: { appState.setMorningPrewarm($0) }
                        ))
                        .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.accent(.claude))
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "clock", title: "Wake Time",
                        subtitle: "Start the window before you sit down") {
                        DatePicker("", selection: morningTimeBinding, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                            .scaleEffect(0.9)
                            .fixedSize()
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "calendar", title: "Weekdays Only",
                        subtitle: "Skip Saturday and Sunday") {
                        Toggle("", isOn: $morningWeekdaysOnly)
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.accent(.claude))
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
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.accent(.claude))
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "checkmark.circle", title: "Window Activated",
                        subtitle: "After warmup succeeds") {
                        Toggle("", isOn: $notifyActivated)
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.accent(.claude))
                    }
                }

                group("SYSTEM") {
                    row(icon: "power", title: "Launch at Login",
                        subtitle: "Start with macOS") {
                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.accent(.claude))
                            .onChange(of: launchAtLogin) { _, v in
                                try? v ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                            }
                    }
                }

                group("PRIVACY") {
                    infoRow(
                        title: "Credential access",
                        detail: "Active tools only. Claude reads Keychain Claude Code-credentials or ~/.claude/.credentials.json. Codex reads auth.json or Keychain Codex Auth."
                    )
                    Divider().background(DS.C.border).padding(.leading, 36)
                    infoRow(
                        title: "Logs",
                        detail: "Tokens and authorization headers are never written to history or warmup logs."
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
                            Text("v1.0  ·  macOS 14+")
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
                                    .padding(.horizontal, 11)
                                    .frame(height: 26)
                                    .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(DS.C.text)
                                    .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border))
                            }
                            .buttonStyle(.plain)
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
        }
        .background(DS.C.bg)
    }

    // MARK: - Layout helpers

    private var morningTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = morningHour
                c.minute = morningMinute
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { newValue in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                morningHour = c.hour ?? 6
                morningMinute = c.minute ?? 0
                appState.morningTimeChanged()
            }
        )
    }

    private var settingsHeader: some View {
        Text("SETTINGS")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(DS.C.textMuted)
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.lg)
            .padding(.bottom, DS.Space.sm)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DS.C.textMuted)
                .padding(.horizontal, DS.Space.lg)
                .padding(.top, DS.Space.md)
                .padding(.bottom, DS.Space.xs)

            VStack(spacing: 0) {
                content()
            }
            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.md))
            .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.C.border, lineWidth: 1))
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.sm)
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
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.C.textMuted)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm + 2)
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
                Button(action: { selected.wrappedValue = opt.value; onChange() }) {
                    Text(opt.label)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(
                            selected.wrappedValue == opt.value
                                ? DS.C.surfaceHigh
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .foregroundStyle(
                            selected.wrappedValue == opt.value
                                ? DS.C.text
                                : DS.C.textMuted
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(DS.C.bg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.C.border, lineWidth: 1))
    }
}
