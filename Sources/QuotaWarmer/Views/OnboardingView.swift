import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var cliStatus: [ToolID: Bool] = [:]
    @State private var checking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.C.yellow).font(.system(size: 12))
                Text("SETUP REQUIRED")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(DS.C.yellow)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.C.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm + 2)
            .background(DS.C.yellow.opacity(0.06))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(DS.C.yellow.opacity(0.15)), alignment: .bottom)

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("Some CLIs were not found in PATH. QuotaWarmer needs them to send warmup messages.")
                    .font(.system(size: 10)).foregroundStyle(DS.C.textSub)
                    .fixedSize(horizontal: false, vertical: true)

                if checking {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.65).tint(DS.C.textMuted)
                        Text("Checking…").font(.system(size: 10)).foregroundStyle(DS.C.textMuted)
                    }
                } else {
                    VStack(spacing: 4) {
                        ForEach(ToolID.allCases) { tool in cliRow(tool) }
                    }
                }
            }
            .padding(DS.Space.lg)

            Divider().background(DS.C.border)

            HStack {
                Button(action: recheck) {
                    Label("Re-check", systemImage: "arrow.clockwise")
                        .font(.system(size: 10)).foregroundStyle(DS.C.textMuted)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: dismiss) {
                    Text("Dismiss")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.sm))
                        .foregroundStyle(DS.C.text)
                        .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm + 2)
        }
        .background(DS.C.bg)
        .task { await runCheck() }
    }

    private func cliRow(_ tool: ToolID) -> some View {
        let found = cliStatus[tool] ?? false
        return HStack(spacing: DS.Space.sm) {
            Image(tool == .claude ? "ClaudeCode" : "Codex")
                .resizable().scaledToFit().frame(width: 16, height: 16)
            Text(tool.displayName)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(DS.C.text)
            Spacer()
            if found {
                Label("Found", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10)).foregroundStyle(DS.C.green)
            } else {
                HStack(spacing: 4) {
                    Label("Not found", systemImage: "xmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(DS.C.red)
                    Button("install →") { openInstallPage(for: tool) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10)).foregroundStyle(DS.C.blue)
                }
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 6)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.sm))
        .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border, lineWidth: 1))
    }

    private func runCheck() async {
        checking = true
        let runner = WarmupRunner()
        for tool in ToolID.allCases {
            let missing = await runner.cliMissing(tool)
            await MainActor.run { cliStatus[tool] = !missing }
        }
        checking = false
    }

    private func recheck() { Task { await runCheck() } }

    private func dismiss() {
        UserDefaults.standard.set(true, forKey: "onboardingDismissed")
        appState.showOnboarding = false
    }

    private func openInstallPage(for tool: ToolID) {
        let urls: [ToolID: String] = [
            .claude: "https://docs.anthropic.com/en/docs/claude-code",
            .codex:  "https://github.com/openai/codex"
        ]
        if let str = urls[tool], let url = URL(string: str) {
            NSWorkspace.shared.open(url)
        }
    }
}
