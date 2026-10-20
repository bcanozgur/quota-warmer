import SwiftUI

/// Settings → Shortcuts: opt-in global hotkey that opens the popover.
struct HotKeySettingsSection: View {
    @ObservedObject private var hotKey = GlobalHotKey.shared
    @AppStorage(HotKeySpec.enabledKey) private var enabled = false
    @AppStorage(HotKeySpec.keyCodeKey) private var keyCode = HotKeySpec.defaultKeyCode
    @AppStorage(HotKeySpec.modifiersKey) private var modifiers = HotKeySpec.defaultModifiers.rawValue

    private var spec: HotKeySpec {
        HotKeySpec(keyCode: keyCode, modifiers: .init(rawValue: modifiers))
    }

    var body: some View {
        VStack(spacing: 0) {
            line(icon: "keyboard", title: "Global Hotkey",
                 subtitle: hotKey.registrationFailed ? "Unavailable — already used by another app"
                     : (enabled && spec.isValid ? "\(spec.display) opens QuotaWarmer" : "Open the popover from anywhere")) {
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    .accessibilityLabel(Text("Global hotkey"))
            }
            if enabled {
                Divider().background(DS.C.border).padding(.leading, 36)
                line(icon: "command", title: "Keys",
                     subtitle: spec.isValid ? "Click to change" : "Include ⌃, ⌥ or ⌘") {
                    HStack(spacing: 4) {
                        modifierPill("⌃", .control)
                        modifierPill("⌥", .option)
                        modifierPill("⇧", .shift)
                        modifierPill("⌘", .command)
                        pill(HotKeySpec.letters.first { $0.code == keyCode }?.label ?? "?", on: true) { cycleKey() }
                    }
                }
            }
        }
        .onChange(of: enabled) { _, _ in hotKey.reload() }
        .onChange(of: keyCode) { _, _ in hotKey.reload() }
        .onChange(of: modifiers) { _, _ in hotKey.reload() }
    }

    private func modifierPill(_ glyph: String, _ flag: HotKeySpec.Modifiers) -> some View {
        let isOn = HotKeySpec.Modifiers(rawValue: modifiers).contains(flag)
        return pill(glyph, on: isOn) {
            var current = HotKeySpec.Modifiers(rawValue: modifiers)
            if isOn { current.remove(flag) } else { current.insert(flag) }
            modifiers = current.rawValue
        }
    }

    private func cycleKey() {
        let letters = HotKeySpec.letters
        let index = letters.firstIndex { $0.code == keyCode } ?? -1
        keyCode = letters[(index + 1) % letters.count].code
    }

    private func pill(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .frame(minWidth: 22)
                .frame(height: 24)
                .background(on ? DS.C.surfaceHigh : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(on ? DS.C.text : DS.C.textMuted)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(DS.C.border, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func line<Control: View>(
        icon: String, title: String, subtitle: String, @ViewBuilder control: () -> Control
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
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(hotKey.registrationFailed && enabled ? DS.C.red : DS.C.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm - 1)
    }
}
