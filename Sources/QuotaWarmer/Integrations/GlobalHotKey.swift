import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey through Carbon `RegisterEventHotKey`, which needs no
/// Accessibility or Input Monitoring permission (unlike NSEvent global
/// monitors). Off unless the user enables it in Settings.
@MainActor
final class GlobalHotKey: ObservableObject {
    static let shared = GlobalHotKey()

    /// Set when the OS refused the combination (usually already taken).
    @Published private(set) var registrationFailed = false
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Registers the saved hotkey (or removes it when disabled/invalid).
    func reload() {
        unregister()
        registrationFailed = false
        guard let spec = HotKeySpec.stored() else { return }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x5157_484B), id: 1) // 'QWHK'
        let status = RegisterEventHotKey(
            UInt32(spec.keyCode), Self.carbonModifiers(spec.modifiers), id,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        if status != noErr {
            hotKeyRef = nil
            registrationFailed = true
            DiagnosticLogger.append("hotkey_register_failed status=\(status)")
        }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.onPress?() } }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }

    static func carbonModifiers(_ modifiers: HotKeySpec.Modifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}
