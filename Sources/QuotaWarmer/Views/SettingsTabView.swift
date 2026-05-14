import SwiftUI
import ServiceManagement

struct SettingsTabView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("refreshInterval")   private var refreshInterval: Int    = 30
    @AppStorage("notifyWarning")     private var notifyWarning: Bool     = true
    @AppStorage("notifyActivated")   private var notifyActivated: Bool   = true
    @AppStorage("launchAtLogin")     private var launchAtLogin: Bool     = false
    @AppStorage("windowDurationHrs") private var windowDurationHrs: Int  = 5

    private let refreshOptions: [(label: String, value: Int)] = [
        ("5s", 5), ("15s", 15), ("30s", 30), ("60s", 60), ("120s", 120)
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                settingsHeader

                group("TIMING") {
                    row(icon: "clock.arrow.2.circlepath", title: "UI Refresh Interval",
                        subtitle: "How often the countdown updates") {
                        segmentedPicker(
                            options: refreshOptions,
                            selected: $refreshInterval
                        ) { appState.applyRefreshInterval() }
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "timer", title: "Window Duration",
                        subtitle: "Match your plan's actual quota window") {
                        segmentedPicker(
                            options: [(label: "4h", value: 4*3600),
                                      (label: "5h", value: 5*3600),
                                      (label: "6h", value: 6*3600)],
                            selected: .init(
                                get: { windowDurationHrs },
                                set: { windowDurationHrs = $0; appState.refreshAllActivity() }
                            )
                        ) {}
                    }
                }

                group("NOTIFICATIONS") {
                    row(icon: "bell.badge", title: "Window Expiring Soon",
                        subtitle: "Alert 30 min before reset") {
                        Toggle("", isOn: $notifyWarning)
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.accent(.claude))
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "checkmark.circle", title: "Window Activated",
                        subtitle: "Confirm when warmup succeeds") {
                        Toggle("", isOn: $notifyActivated)
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.accent(.claude))
                    }
                }

                group("SYSTEM") {
                    row(icon: "power", title: "Launch at Login",
                        subtitle: "Start QuotaWarmer on macOS login") {
                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.accent(.claude))
                            .onChange(of: launchAtLogin) { _, v in
                                try? v ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                            }
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "arrow.clockwise", title: "Refresh Now",
                        subtitle: "Re-scan log files immediately") {
                        Button(action: { appState.refreshAllActivity() }) {
                            Text("Refresh")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.sm))
                                .foregroundStyle(DS.C.text)
                                .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }

                group("ABOUT") {
                    HStack(spacing: DS.Space.md) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(DS.C.accent(.claude))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("QuotaWarmer")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.text)
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
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.sm))
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
                .font(.system(size: 12))
                .foregroundStyle(DS.C.textSub)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.C.text)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(DS.C.textMuted)
            }
            Spacer()
            control()
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
