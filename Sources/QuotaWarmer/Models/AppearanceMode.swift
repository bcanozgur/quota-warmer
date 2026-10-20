import Foundation

/// The panel's color theme. `.system` follows macOS (and switches live when
/// the system does); `.light` / `.dark` pin it. Cycled by the sidebar button.
enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    static let defaultsKey = AppSettings.Key.appearanceMode

    /// Sidebar button order: System → Light → Dark → System.
    var next: AppearanceMode {
        switch self {
        case .system: return .light
        case .light:  return .dark
        case .dark:   return .system
        }
    }

    /// SF Symbol that names the theme itself: half-filled circle = follows the
    /// system, sun = light, moon = dark.
    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    var label: String {
        switch self {
        case .system: return String(localized: "System")
        case .light:  return String(localized: "Light")
        case .dark:   return String(localized: "Dark")
        }
    }

    static func stored(defaults: UserDefaults = .standard) -> AppearanceMode {
        defaults.string(forKey: defaultsKey).flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }
}
