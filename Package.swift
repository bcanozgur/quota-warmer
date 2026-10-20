// swift-tools-version:5.10
import PackageDescription

// Test-only package. The app itself is still built from project.yml (XcodeGen);
// this package compiles the app's UI-free Models/Services files *in place* so the
// regression suites run with one command: `swift test`.
//
// QuotaWarmerCore.sources is the single list of files the suites compile against.
// When a regression suite needs a new Models/Services file, add it here — nowhere else.
let package = Package(
    name: "QuotaWarmer",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "QuotaWarmerCore",
            path: "Sources/QuotaWarmer",
            sources: [
                "Models/AppSettings.swift",
                "Models/AppearanceMode.swift",
                "Models/AutoWarmDecision.swift",
                "Models/AutoWarmExplanation.swift",
                "Models/EventLog.swift",
                "Models/ImpactReport.swift",
                "Models/IntegrationCommand.swift",
                "Models/OnboardingFlow.swift",
                "Models/ProviderAccount.swift",
                "Models/QuotaAlerts.swift",
                "Models/QuotaDisplay.swift",
                "Models/QuotaModels.swift",
                "Models/QuotaStatus.swift",
                "Models/TimeInput.swift",
                "Models/ToolID.swift",
                "Models/UsageHistory.swift",
                "Services/CredentialStore.swift",
                "Services/DiagnosticLogger.swift",
                "Services/LocalUsageProvider.swift",
                "Services/ModelCatalog.swift",
                "Services/QuotaProvider.swift",
                "Services/WarmupRunner.swift",
            ]
        ),
        .testTarget(
            name: "RegressionTests",
            dependencies: ["QuotaWarmerCore"],
            path: "Tests/RegressionTests"
        ),
    ]
)
