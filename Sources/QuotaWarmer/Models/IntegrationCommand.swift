import Foundation

/// Panel tabs a `quotawarmer://open` link may select.
enum IntegrationTab: String, CaseIterable {
    case main, history, settings
}

/// What a `quotawarmer://` URL asks for. Deliberately read-only: any web page
/// can open a URL, so there is no command here that sends a warm-up or changes
/// a mode or setting. Adding one would hand that power to every web page.
enum IntegrationCommand: Equatable {
    /// Show the popover, optionally on a tab.
    case open(tab: IntegrationTab?)
    /// Refresh quota now (subject to the rate-limit backoff). `provider` is a
    /// `ProviderID.storageKey` (`claude`, `codex`, `claude.work`); nil = all.
    case refresh(provider: String?)
}

enum IntegrationURL {
    static let scheme = "quotawarmer"

    /// Parses `quotawarmer://open[?tab=…]` and `quotawarmer://refresh[?provider=…]`.
    /// Strict: anything else (unknown action, unknown or repeated query key,
    /// bad value, credentials, port, path, fragment) yields nil and is ignored.
    static func parse(_ url: URL) -> IntegrationCommand? {
        guard url.scheme?.lowercased() == scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let action = parts.host?.lowercased()
        else { return nil }

        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value, !value.isEmpty else { return nil }
            values[item.name] = value
        }

        switch action {
        case "open":
            guard Set(values.keys).isSubset(of: ["tab"]) else { return nil }
            guard let raw = values["tab"] else { return .open(tab: nil) }
            guard let tab = IntegrationTab(rawValue: raw.lowercased()) else { return nil }
            return .open(tab: tab)
        case "refresh":
            guard Set(values.keys).isSubset(of: ["provider"]) else { return nil }
            guard let raw = values["provider"] else { return .refresh(provider: nil) }
            guard isValidProviderKey(raw) else { return nil }
            return .refresh(provider: raw.lowercased())
        default:
            return nil
        }
    }

    /// Shape of a `ProviderID.storageKey`; the key is then matched against the
    /// real accounts, so this only keeps junk out of logs.
    static func isValidProviderKey(_ value: String) -> Bool {
        guard (1...80).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            ("a"..."z").contains(Character($0)) || ("A"..."Z").contains(Character($0))
                || ("0"..."9").contains(Character($0)) || $0 == "." || $0 == "-" || $0 == "_"
        }
    }
}

/// Throttle for refreshes requested from outside the app (URL, Shortcuts), so a
/// page or loop that fires the same link repeatedly cannot hammer the provider.
struct IntegrationRefreshThrottle {
    static let minimumInterval: TimeInterval = 30
    private var last: [String: Date] = [:]

    /// True (and records `now`) when `key` may refresh; false while throttled.
    mutating func allow(_ key: String, now: Date = Date()) -> Bool {
        if let previous = last[key], now.timeIntervalSince(previous) < Self.minimumInterval { return false }
        last[key] = now
        return true
    }
}

/// A global hotkey for opening the popover: a key (`kVK_ANSI_*` code) plus
/// modifier flags. Stored in `UserDefaults`; off by default.
struct HotKeySpec: Equatable {
    static let enabledKey = AppSettings.Key.globalHotKeyEnabled
    static let keyCodeKey = AppSettings.Key.globalHotKeyCode
    static let modifiersKey = AppSettings.Key.globalHotKeyModifiers

    /// Modifier bits stored in defaults (independent of Carbon's values).
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option  = Modifiers(rawValue: 1 << 1)
        static let shift   = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    /// Keys offered in Settings: ANSI letters (with their `kVK_ANSI_*` codes).
    static let letters: [(label: String, code: Int)] = [
        ("A", 0x00), ("S", 0x01), ("D", 0x02), ("F", 0x03), ("H", 0x04), ("G", 0x05), ("Z", 0x06),
        ("X", 0x07), ("C", 0x08), ("V", 0x09), ("B", 0x0B), ("Q", 0x0C), ("W", 0x0D), ("E", 0x0E),
        ("R", 0x0F), ("Y", 0x10), ("T", 0x11), ("O", 0x1F), ("U", 0x20), ("I", 0x22), ("P", 0x23),
        ("L", 0x25), ("J", 0x26), ("K", 0x28), ("N", 0x2D), ("M", 0x2E)
    ]

    static let defaultKeyCode = 0x0C // Q
    static let defaultModifiers: Modifiers = [.control, .option]

    var keyCode: Int
    var modifiers: Modifiers

    /// A hotkey needs at least one of control/option/command, or it would
    /// swallow ordinary typing.
    var isValid: Bool {
        Self.letters.contains { $0.code == keyCode }
            && !modifiers.isDisjoint(with: [.control, .option, .command])
    }

    /// "⌃⌥Q".
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.letters.first { $0.code == keyCode }?.label ?? "?")
    }

    /// The saved hotkey when the feature is on and the combination is valid.
    static func stored(_ defaults: UserDefaults = .standard) -> HotKeySpec? {
        guard defaults.bool(forKey: enabledKey) else { return nil }
        let code = defaults.object(forKey: keyCodeKey) as? Int ?? defaultKeyCode
        let mods = defaults.object(forKey: modifiersKey) as? Int ?? defaultModifiers.rawValue
        let spec = HotKeySpec(keyCode: code, modifiers: Modifiers(rawValue: mods))
        return spec.isValid ? spec : nil
    }
}
