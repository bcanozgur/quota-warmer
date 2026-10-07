import AppKit
import SwiftUI

/// Settings › Accounts: extra Claude / Codex accounts, each in its own CLI
/// home (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`) so it can stay signed in next to
/// the default one.
struct AccountsSection: View {
    @EnvironmentObject var appState: AppState

    @State private var addingKind: ToolID?
    @State private var draftName = ""
    @State private var draftHome = ""
    @State private var homeEdited = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ToolID.allCases) { kind in
                defaultRow(kind)
                divider
                ForEach(appState.providers.filter { $0.kind == kind && !$0.isDefault }) { tool in
                    AccountRow(tool: tool, toolState: appState.state(for: tool))
                    divider
                }
            }
            if let addingKind {
                addForm(addingKind)
            } else {
                addButtons
            }
        }
    }

    private var divider: some View {
        Divider().background(DS.C.border).padding(.leading, 36)
    }

    private func defaultRow(_ kind: ToolID) -> some View {
        HStack(spacing: DS.Space.sm) {
            AccountGlyph(tool: .default(kind))
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.shortName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.C.text)
                Text(kind == .claude ? "~/.claude · default" : "~/.codex · default")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.C.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm - 1)
    }

    private var addButtons: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.C.textSub)
                .frame(width: 20)
            Text("Add account")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DS.C.text)
            Spacer()
            ForEach(ToolID.allCases) { kind in
                SmallButton(title: kind.shortName, systemImage: "plus") { startAdding(kind) }
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
    }

    private func addForm(_ kind: ToolID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New \(kind.shortName) account")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(DS.C.text)
            labeledField("Name") {
                DSTextField(placeholder: "Work", text: $draftName)
                    .onChange(of: draftName) { _, name in
                        if !homeEdited { draftHome = suggestedHome(kind, name: name) }
                    }
            }
            labeledField("Folder") {
                HStack(spacing: 6) {
                    DSTextField(placeholder: "~/.\(kind.rawValue)-work", text: Binding(
                        get: { draftHome },
                        set: { draftHome = $0; homeEdited = true }
                    ))
                    SmallButton(title: "Choose…", systemImage: nil) { chooseFolder() }
                }
            }
            Text("The \(kind == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME") this account's CLI uses. A new folder is created; pick an existing one if you already sign in there.")
                .font(.system(size: 9.5))
                .foregroundStyle(DS.C.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.C.red)
            }
            HStack(spacing: 6) {
                Spacer()
                SmallButton(title: "Cancel", systemImage: nil) { cancelAdding() }
                SmallButton(title: "Add", systemImage: nil, prominent: DS.C.accent(kind)) { commitAdd(kind) }
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm + 2)
    }

    private func labeledField<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DS.C.textSub)
                .frame(width: 42, alignment: .leading)
            field()
        }
    }

    private func suggestedHome(_ kind: ToolID, name: String) -> String {
        let existing = appState.accounts.map(\.home)
        return ProviderAccount.suggestedHome(kind: kind, name: name.isEmpty ? "work" : name, existing: existing)
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func startAdding(_ kind: ToolID) {
        addingKind = kind
        draftName = ""
        homeEdited = false
        draftHome = suggestedHome(kind, name: "")
        errorText = nil
    }

    private func cancelAdding() {
        addingKind = nil
        errorText = nil
    }

    private func commitAdd(_ kind: ToolID) {
        do {
            let tool = try appState.addAccount(kind: kind, name: draftName, home: draftHome)
            addingKind = nil
            errorText = nil
            // Signing in is the one step left; open it straight away.
            AccountLogin.openTerminal(for: tool)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = "Use Folder"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            draftHome = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            homeEdited = true
        }
    }
}

/// One added account: name, folder, sign-in state and actions.
private struct AccountRow: View {
    @EnvironmentObject var appState: AppState
    let tool: ProviderID
    @ObservedObject var toolState: ToolState

    @State private var renaming = false
    @State private var draftName = ""
    @State private var confirmRemove = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.Space.sm) {
                AccountGlyph(tool: tool)
                VStack(alignment: .leading, spacing: 1) {
                    if renaming {
                        DSTextField(placeholder: "Name", text: $draftName, onSubmit: commitRename)
                    } else {
                        Text(tool.shortName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DS.C.text)
                            .lineLimit(1)
                    }
                    Text(displayHome)
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.C.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(tool.home ?? "")
                }
                Spacer(minLength: 4)
                statusBadge
            }
            HStack(spacing: 6) {
                Spacer().frame(width: 28)
                if needsSignIn {
                    SmallButton(title: "Sign in", systemImage: "terminal", prominent: DS.C.accent(tool)) {
                        AccountLogin.openTerminal(for: tool)
                    }
                    .help(tool.loginCommand)
                }
                SmallButton(title: copied ? "Copied" : "Copy command", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AccountLogin.cliAlias(for: tool), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                .help("Copies a shell alias that runs \(tool.kind == .claude ? "claude" : "codex") as this account:\n\(AccountLogin.cliAlias(for: tool))")
                Spacer()
                if renaming {
                    SmallButton(title: "Save", systemImage: nil) { commitRename() }
                } else {
                    IconButton(systemName: "pencil", help: "Rename", size: 22) {
                        draftName = tool.name
                        renaming = true
                    }
                }
                if confirmRemove {
                    SmallButton(title: "Remove", systemImage: nil, prominent: DS.C.red) {
                        appState.removeAccount(tool)
                    }
                    .help("Stops watching this account. Its folder and login stay on disk.")
                } else {
                    IconButton(systemName: "trash", help: "Remove account", size: 22) {
                        confirmRemove = true
                        Task { try? await Task.sleep(nanoseconds: 4_000_000_000); confirmRemove = false }
                    }
                }
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
    }

    private var displayHome: String {
        (tool.home ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var needsSignIn: Bool {
        toolState.authStatus == .missing || toolState.authStatus == .failed
            || toolState.sourceHealth == .authFailure
            || (toolState.quotaSnapshot == nil && !toolState.isFetchingQuota)
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            if toolState.isFetchingQuota { return ("Checking", DS.C.textMuted) }
            if toolState.quotaSnapshot != nil, toolState.sourceHealth == .healthy { return ("Signed in", DS.C.green) }
            if needsSignIn { return ("Not signed in", DS.C.yellow) }
            return ("Stale", DS.C.yellow)
        }()
        return StatusBadge(text: text, color: color)
    }

    private func commitRename() {
        appState.renameAccount(tool, to: draftName)
        renaming = false
    }
}

/// Provider glyph with the account's initial badge.
private struct AccountGlyph: View {
    let tool: ProviderID

    var body: some View {
        Image(tool.kind.glyphAssetName)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 15, height: 15)
            .foregroundStyle(DS.C.textSub)
            .overlay(alignment: .bottomTrailing) {
                if let badge = tool.badge {
                    AccountBadge(text: badge, color: DS.C.accent(tool))
                        .scaleEffect(0.85)
                        .offset(x: 6, y: 5)
                }
            }
            .frame(width: 20)
    }
}

/// Opens Terminal on a one-off script that signs an account in.
enum AccountLogin {
    /// `alias claude-work="CLAUDE_CONFIG_DIR='…' claude"` for everyday use.
    static func cliAlias(for tool: ProviderID) -> String {
        let cli = tool.kind == .claude ? "claude" : "codex"
        let slug = ProviderAccount.slugified(tool.name)
        let name = "\(cli)-\(slug.isEmpty ? tool.accountID : slug)"
        guard let home = tool.home else { return cli }
        return "alias \(name)=\"\(tool.homeEnvironmentVariable)=\(ProviderID.shellQuoted(home)) \(cli)\""
    }

    static func openTerminal(for tool: ProviderID) {
        let script = """
        #!/bin/zsh -l
        clear
        echo "QuotaWarmer — sign in \(tool.displayName)"
        echo "Log in with the account you want QuotaWarmer to watch here."
        echo
        \(tool.loginCommand)
        echo
        echo "Done. QuotaWarmer will pick this account up on its next check (or press Refresh)."
        echo "To use this account yourself, add to ~/.zshrc:"
        echo
        echo \(ProviderID.shellQuoted("  " + cliAlias(for: tool)))
        echo
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaWarmerLogin", isDirectory: true)
        let url = dir.appendingPathComponent("signin-\(tool.storageKey).command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            DiagnosticLogger.append("account_login_script_failed account=\(tool.storageKey)")
        }
    }
}

/// Compact capsule button used in the Accounts section.
struct SmallButton: View {
    let title: String
    let systemImage: String?
    var prominent: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                }
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(prominent == nil ? DS.C.textSub : .white)
            .background(prominent ?? DS.C.surfaceHigh, in: Capsule())
            .overlay(Capsule().stroke(prominent == nil ? DS.C.border : .clear, lineWidth: 1))
            .fixedSize()
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// Plain single-line text field in the DS look (see `WakeTimeField` for why
/// AppKit-styled fields are avoided in this scaled panel).
struct DSTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(DS.C.text)
            .focused($focused)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(focused ? DS.C.blue.opacity(0.6) : DS.C.border, lineWidth: 1)
            )
            .onSubmit(onSubmit)
    }
}
