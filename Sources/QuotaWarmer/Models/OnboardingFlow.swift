import Foundation

/// Pure logic for the first-run welcome guide: which steps exist, and whether a
/// given launch should show the full guide, only the missing-CLI banner, or
/// nothing. AppState gathers the inputs; nothing here touches UserDefaults.
enum OnboardingStep: Int, CaseIterable, Equatable {
    case welcome, cliCheck, modes, permissions, optional

    var title: String {
        switch self {
        case .welcome:     return String(localized: "Welcome")
        case .cliCheck:    return String(localized: "Command-line tools")
        case .modes:       return String(localized: "Choose a mode")
        case .permissions: return String(localized: "Permissions")
        case .optional:    return String(localized: "Optional extras")
        }
    }

    var isFirst: Bool { self == OnboardingStep.allCases.first }
    var isLast: Bool { self == OnboardingStep.allCases.last }
    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

enum OnboardingFlow {
    /// Bump when the guide changes enough that completed users should see it again
    /// (existing users are still never forced into it; see `launchDecision`).
    static let currentVersion = 1

    struct Decision: Equatable {
        /// Show the full step-based guide.
        var showGuide: Bool
        /// Show the compact "a required CLI is missing" banner.
        var showMissingCLIBanner: Bool
        /// Record `onboardingCompletedVersion = currentVersion` right away
        /// (upgrading users skip the guide but must not be re-evaluated).
        var markCompleted: Bool
    }

    /// - completedVersion: persisted `onboardingCompletedVersion`, nil if never set.
    /// - hadPriorSettings: QuotaWarmer UserDefaults existed before this launch.
    /// - anyCLIMissing / bannerDismissed: the existing missing-CLI behavior.
    static func launchDecision(completedVersion: Int?, hadPriorSettings: Bool,
                               anyCLIMissing: Bool, bannerDismissed: Bool) -> Decision {
        let banner = anyCLIMissing && !bannerDismissed
        if let completed = completedVersion, completed >= currentVersion {
            return Decision(showGuide: false, showMissingCLIBanner: banner, markCompleted: false)
        }
        if hadPriorSettings {
            // Upgrade: keep the old behavior, record that we have decided.
            return Decision(showGuide: false, showMissingCLIBanner: banner, markCompleted: true)
        }
        // First launch: the guide's CLI step covers a missing CLI, so no banner.
        return Decision(showGuide: true, showMissingCLIBanner: false, markCompleted: false)
    }

    /// UserDefaults keys that macOS/AppKit/Sparkle-style frameworks write on
    /// their own and so say nothing about a prior QuotaWarmer install.
    static func isSystemKey(_ key: String) -> Bool {
        let prefixes = ["NS", "Apple", "com.apple", "AK", "SU", "WebKit", "PayloadKey", "INNext"]
        return prefixes.contains { key.hasPrefix($0) }
    }

    static func hasPriorSettings(keys: [String]) -> Bool {
        keys.contains { !isSystemKey($0) }
    }

    /// Install command shown (with a copy button) when a CLI is missing.
    static func installCommand(for tool: ToolID) -> String {
        switch tool {
        case .claude: return "npm install -g @anthropic-ai/claude-code"
        case .codex:  return "npm install -g @openai/codex"
        }
    }
}
