import Testing
@testable import QuotaWarmerCore

/// Runs the three regression suites under `swift test`.
///
/// Each suite keeps its original assertion helpers: a failing check prints
/// `FAIL: …` and stops the run (`exit(1)` / `fatalError`), so `swift test`
/// fails with the message in its output. The suites share process-wide state
/// (UserDefaults suites, catalog stores, DebugLevel), so they run serialized.
@Suite(.serialized)
struct RegressionTests {
    @Test func quotaExtractor() async {
        await QuotaExtractorRegression.main()
    }

    @Test func quotaDisplay() async {
        await QuotaDisplayRegression.main()
    }

    @Test func accountsHistory() async {
        await AccountsHistoryRegression.main()
    }
}
