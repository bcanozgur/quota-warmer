import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

/// First-run guide, shown in the popover's content column (the sidebar stays
/// visible). It lives in the existing panel rather than a separate window: the
/// app is an agent with no Dock icon, so a second window would need extra
/// activation handling and could be lost behind other apps, while the panel is
/// exactly where the user just clicked. Every step is skippable.
struct WelcomeGuideView: View {
    @EnvironmentObject var appState: AppState
    @State private var step: OnboardingStep = .welcome
    @State private var cliInfo: [ToolID: (path: String, version: String?)?] = [:]
    @State private var claudeSignedIn: Bool?
    @State private var checking = false
    @State private var copied: ToolID?
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    switch step {
                    case .welcome:     welcome
                    case .cliCheck:    cliCheck
                    case .modes:       modes
                    case .permissions: permissions
                    case .optional:    optionalExtras
                    }
                }
                .padding(DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().background(DS.C.border)
            footer
        }
        .background(DS.C.bg)
        .task { await runCheck() }
        .task { await refreshNotificationStatus() }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("STEP \(step.rawValue + 1) OF \(OnboardingStep.allCases.count)")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(DS.C.textMuted)
                Spacer()
                Button("Skip guide") { appState.finishWelcomeGuide() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10)).foregroundStyle(DS.C.textMuted)
            }
            Text(step.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.C.text)
            HStack(spacing: 4) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Capsule().fill(s.rawValue <= step.rawValue ? DS.C.ink : DS.C.track).frame(height: 3)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, DS.Space.md).padding(.top, DS.Space.md).padding(.bottom, DS.Space.sm)
    }

    private var footer: some View {
        HStack {
            if let previous = step.previous {
                button("Back", prominent: false) { step = previous }
            }
            Spacer()
            if let next = step.next {
                button("Next", prominent: true) { step = next }
            } else {
                button("Done", prominent: true) { appState.finishWelcomeGuide() }
            }
        }
        .padding(.horizontal, DS.Space.md).padding(.vertical, 8)
    }

    private func button(_ title: LocalizedStringKey, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(prominent ? DS.C.ink : DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.sm))
                .foregroundStyle(prominent ? DS.C.bg : DS.C.text)
                .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func body(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(DS.C.textSub)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5, content: content)
            .padding(DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.sm))
            .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border, lineWidth: 1))
    }

    // MARK: - Steps

    private var welcome: some View {
        Group {
            body("QuotaWarmer lives in your menu bar and watches your Claude Code and Codex 5-hour quota windows, so you always know how much is left and when it resets.")
            body("It starts in Monitor mode, which only reads your quota and sends nothing. Automatic warm-up is an opt-in you can enable per tool.")
        }
    }

    private var cliCheck: some View {
        Group {
            body("Warm-ups run through the official CLIs you already use. Monitoring only needs you to be signed in.")
            ForEach(ToolID.allCases) { tool in cliCard(tool) }
            HStack {
                Button { Task { await runCheck() } } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                        .font(.system(size: 10)).foregroundStyle(DS.C.textMuted)
                }
                .buttonStyle(.plain)
                if checking { ProgressView().scaleEffect(0.55) }
            }
        }
    }

    private func cliCard(_ tool: ToolID) -> some View {
        let known = cliInfo[tool] != nil
        let info = cliInfo[tool] ?? nil
        return card {
            HStack(spacing: DS.Space.sm) {
                Image(tool == .claude ? "ClaudeCode" : "Codex")
                    .resizable().scaledToFit().frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(tool.shortName).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.C.text)
                Spacer()
                if !known {
                    Text("Checking…").font(.system(size: 10)).foregroundStyle(DS.C.textMuted)
                } else if info != nil {
                    Label("Found", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(DS.C.green)
                } else {
                    Label("Not found", systemImage: "xmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(DS.C.red)
                }
            }
            if let info {
                Text(info.path + (info.version.map { " · \($0)" } ?? ""))
                    .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(DS.C.textMuted)
                    .lineLimit(2).truncationMode(.middle)
                if tool == .claude, let signedIn = claudeSignedIn {
                    Text(signedIn ? "Signed in" : "Not signed in — run `claude auth login` in a terminal")
                        .font(.system(size: 10)).foregroundStyle(signedIn ? DS.C.green : DS.C.yellow)
                }
            } else if known {
                Text("Install it, then press Re-check:")
                    .font(.system(size: 10)).foregroundStyle(DS.C.textSub)
                HStack(spacing: 6) {
                    Text(OnboardingFlow.installCommand(for: tool))
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(DS.C.text)
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied == tool ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(OnboardingFlow.installCommand(for: tool), forType: .string)
                        copied = tool
                    }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(DS.C.blue)
                }
            }
        }
    }

    private var modes: some View {
        Group {
            body("Pick a mode for each tool. You can change it any time from the tool's tab.")
            ForEach(ToolID.allCases) { tool in
                let provider = ProviderID.default(tool)
                let mode = appState.state(for: provider).mode
                card {
                    HStack {
                        Text(tool.shortName).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.C.text)
                        Spacer()
                        Picker(selection: Binding(
                            get: { appState.state(for: provider).mode },
                            set: { appState.setMode($0, for: provider) }
                        )) {
                            ForEach(ToolMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        } label: {
                            Text("\(tool.shortName) mode")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                    }
                    Text(blurb(mode)).font(.system(size: 10)).foregroundStyle(DS.C.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Is this allowed?").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.C.text)
            body("QuotaWarmer uses capacity you already pay for, through the official CLI you're already signed into. It never bypasses or raises your limits, never shares or uploads your credentials, and sends nothing at all for tools left on Monitor or Off. Providers may change their APIs at any time; if automated warm-up is ever disallowed, set a tool to Monitor and QuotaWarmer keeps tracking your quota.")
        }
    }

    private func blurb(_ mode: ToolMode) -> String {
        switch mode {
        case .off:      return String(localized: "Off — not watched at all.")
        case .monitor:  return String(localized: "Monitor — shows quota and alerts. Never sends anything. (Default)")
        case .autoWarm: return String(localized: "Auto-warm — also sends one minimal \"hi\" through the CLI when a fresh window opens.")
        }
    }

    private var permissions: some View {
        Group {
            card {
                Text("Notifications").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.C.text)
                Text("Used for quota alerts and warm-up confirmations.")
                    .font(.system(size: 10)).foregroundStyle(DS.C.textSub)
                HStack {
                    Text(notificationLabel).font(.system(size: 10)).foregroundStyle(DS.C.textMuted)
                    Spacer()
                    if notificationStatus != .authorized {
                        Button("Allow notifications") {
                            NotificationManager.shared.requestPermission()
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                await refreshNotificationStatus()
                            }
                        }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(DS.C.blue)
                    }
                }
            }
            card {
                Text("Keychain").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.C.text)
                Text("To read your quota, QuotaWarmer reads the sign-in token Claude Code and Codex already store on your Mac (Keychain or their auth files). The token is only sent to the provider's own usage endpoint. macOS may ask once for your login password when you press Refresh; background checks never show a Keychain prompt.")
                    .font(.system(size: 10)).foregroundStyle(DS.C.textSub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notificationLabel: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return String(localized: "Allowed")
        case .denied: return String(localized: "Blocked — enable in System Settings → Notifications")
        default: return String(localized: "Not asked yet")
        }
    }

    private var optionalExtras: some View {
        Group {
            body("Both are off by default and can be changed later in Settings.")
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wake & warm each morning").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.C.text)
                        Text("Schedules your Mac to wake before your day starts and opens a fresh window. Turning it on shows one macOS administrator prompt (pmset needs root). Only applies to tools set to Auto-warm.")
                            .font(.system(size: 10)).foregroundStyle(DS.C.textSub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle(isOn: Binding(
                        get: { appState.morningPrewarmEnabled },
                        set: { appState.setMorningPrewarm($0) }
                    )) { Text("Wake & warm each morning") }
                    .labelsHidden()
                    .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                }
            }
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.C.text)
                        Text("Keeps quota tracking running after a restart.")
                            .font(.system(size: 10)).foregroundStyle(DS.C.textSub)
                        if let launchError {
                            Text(launchError).font(.system(size: 9.5)).foregroundStyle(DS.C.red)
                        }
                    }
                    Spacer()
                    Toggle(isOn: $launchAtLogin) { Text("Launch at login") }
                        .labelsHidden()
                        .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                        .onChange(of: launchAtLogin) { _, v in setLaunchAtLogin(v) }
                }
            }
        }
    }

    // MARK: - Actions

    private func runCheck() async {
        checking = true
        let runner = WarmupRunner()
        for tool in ToolID.allCases {
            let info = await runner.cliInfo(tool)
            cliInfo[tool] = .some(info)
        }
        if cliInfo[.claude] ?? nil != nil {
            claudeSignedIn = await runner.cliAuthenticationStatus(for: .default(.claude)).isAuthenticated
        } else {
            claudeSignedIn = nil
        }
        checking = false
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = String(localized: "Could not change: \(error.localizedDescription)")
        }
        let actual = SMAppService.mainApp.status == .enabled
        UserDefaults.standard.set(actual, forKey: "launchAtLogin")
        if launchAtLogin != actual { launchAtLogin = actual }
    }
}
