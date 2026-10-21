import Foundation

/// The app's UI language. `.system` follows macOS (System Settings → General →
/// Language & Region, including its per-app list); the others pin it.
///
/// Stored the way macOS stores a per-app language: an `AppleLanguages` array
/// in the app's own defaults domain, read by `Bundle` once at launch — so a
/// change takes effect after a relaunch. Choosing System removes the key so
/// the global list applies again.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case turkish = "tr"

    static let defaultsKey = "AppleLanguages"

    var id: String { rawValue }

    /// Each language in its own name, so it can be found whatever the UI
    /// language currently is. System is translated.
    var label: String {
        switch self {
        case .system:  return String(localized: "System")
        case .english: return "English"
        case .turkish: return "Türkçe"
        }
    }

    /// The choice stored in the app's own domain. `defaults.array(forKey:)`
    /// would also see the global language list and always report a language;
    /// only the app domain says whether the user pinned one.
    static func stored(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) -> AppLanguage {
        guard let domain,
              let first = (defaults.persistentDomain(forName: domain)?[defaultsKey] as? [String])?.first
        else { return .system }
        // "tr", "tr-TR" and "tr_TR" all mean Turkish.
        let code = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? first
        return AppLanguage(rawValue: code.lowercased()) ?? .system
    }

    /// Writes the choice; it applies from the next launch.
    func store(defaults: UserDefaults = .standard) {
        switch self {
        case .system: defaults.removeObject(forKey: Self.defaultsKey)
        default:      defaults.set([rawValue], forKey: Self.defaultsKey)
        }
    }

    /// The language this run was launched with, read once — Settings compares
    /// it with the stored choice to offer a relaunch.
    static let atLaunch = AppLanguage.stored()
}
