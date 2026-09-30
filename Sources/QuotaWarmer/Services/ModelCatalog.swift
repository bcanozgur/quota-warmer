import Foundation

/// Model prices and the ordered warm-up model list for one CLI, kept as data in
/// `Resources/<tool>-models.json` (`claude-models.json`, `codex-models.json`)
/// so a new model or price change ships without an app release: the file is
/// bundled as the offline default and the same file on `main` is fetched as
/// the live copy (`ModelCatalogStore`). Bump `revision` on every edit —
/// clients only adopt a higher revision. The `upstream` block in the JSON is
/// read only by `scripts/check-model-catalog.py`.
struct ModelCatalog: Codable, Equatable {
    struct Warmup: Codable, Equatable {
        /// Tried in order; each is passed to the CLI's `--model`. Order by the
        /// measured cost of one warm-up, which can differ from per-token price
        /// (Codex sends a model-specific system prompt).
        let models: [String]
        /// Catalog id of the cheapest warm-up candidate known when the list was
        /// last reviewed. The upstream check flags a newly cheaper model.
        let cheapestModel: String?
    }

    /// How a catalog id is compared with a model string from a CLI log.
    enum MatchMode: String, Codable, Equatable {
        /// The id appears as a whole name anywhere in the string, optionally
        /// followed by a snapshot/context suffix (Claude: `claude-opus-5-5[1m]`).
        case name
        /// The last path component equals the id (`openai/gpt-5.5`).
        case exact
        /// The last path component is the id or starts with `<id>-`.
        case prefix
    }

    struct Model: Codable, Equatable {
        /// Model family, e.g. `opus-5-5` or `gpt-5.6-luna`. Compared after
        /// `normalize`, so dots and dashes are interchangeable.
        let id: String
        let name: String?
        /// Extra names matched the same way as `id` (older naming schemes,
        /// logical labels such as `codex-auto-review`).
        let aliases: [String]?
        /// Overrides the catalog's `defaultMatch`.
        let match: MatchMode?
        /// USD per million tokens.
        let input: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        let cacheRead: Double
        let output: Double
    }

    /// Inputs above `inputTokensAbove` are billed at multiplied rates (OpenAI).
    struct LongContext: Codable, Equatable {
        let inputTokensAbove: Int
        let inputMultiplier: Double
        let outputMultiplier: Double
    }

    static let supportedSchemaVersion = 1
    static let maxWarmupModelLength = 64

    let schemaVersion: Int
    let revision: Int
    let updatedAt: String?
    let source: String?
    let warmup: Warmup
    /// Exact (normalized) model strings that name a model by alias, e.g. `haiku`.
    let aliases: [String: String]?
    let defaultMatch: MatchMode?
    /// Model used to price log records that carry no model at all (older
    /// Codex session files).
    let unlabeledModel: String?
    let longContext: LongContext?
    let models: [Model]

    static func decode(_ data: Data) throws -> ModelCatalog {
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
        if let problem = catalog.validationProblem() {
            throw CatalogError.invalid(problem)
        }
        return catalog
    }

    enum CatalogError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return "Invalid model catalog: \(reason)"
            }
        }
    }

    /// The remote copy is untrusted input: prices only feed a display estimate,
    /// but warm-up model names are interpolated into a `zsh -lc` command, so
    /// they are restricted to a plain model-id alphabet.
    func validationProblem() -> String? {
        guard schemaVersion == Self.supportedSchemaVersion else { return "unsupported schemaVersion \(schemaVersion)" }
        guard revision >= 1 else { return "revision must be >= 1" }
        guard !models.isEmpty else { return "no models" }
        var ids = Set<String>()
        for model in models {
            guard Self.isPlainIdentifier(Self.normalize(model.id)), ids.insert(model.id).inserted else {
                return "bad or duplicate model id \(model.id)"
            }
            let prices = [model.input, model.cacheWrite5m, model.cacheWrite1h, model.cacheRead, model.output]
            guard prices.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 10_000 }),
                  model.input > 0, model.output > 0 else {
                return "bad prices for \(model.id)"
            }
            for alias in model.aliases ?? [] where !Self.isPlainIdentifier(Self.normalize(alias)) {
                return "bad alias \(alias)"
            }
        }
        for (alias, target) in aliases ?? [:] where !ids.contains(target) || alias.isEmpty {
            return "alias \(alias) points at unknown model \(target)"
        }
        if let unlabeledModel, self.model(for: unlabeledModel) == nil {
            return "unlabeledModel \(unlabeledModel) does not resolve"
        }
        if let longContext {
            guard longContext.inputTokensAbove > 0,
                  [longContext.inputMultiplier, longContext.outputMultiplier].allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= 10 }) else {
                return "bad longContext"
            }
        }
        guard !warmup.models.isEmpty else { return "no warm-up models" }
        for model in warmup.models where !Self.isSafeWarmupModel(model) {
            return "unsafe warm-up model name"
        }
        return nil
    }

    /// Lowercase letters, digits, `-` and `.`, starting with a letter or digit.
    static func isSafeWarmupModel(_ model: String) -> Bool {
        guard let first = model.first, model.count <= maxWarmupModelLength,
              first.isASCII, first.isLetter || first.isNumber else { return false }
        return model.allSatisfy { char in
            char.isASCII && (char.isLowercase || char.isNumber || char == "-" || char == ".")
        }
    }

    private static func isPlainIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy { char in
            char.isASCII && (char.isLowercase || char.isNumber || char == "-")
        }
    }

    /// `Claude Opus 5.5`, `claude-opus-5.5`, `anthropic.claude_opus_5_5` all
    /// normalize to the same dash-separated lowercase form.
    static func normalize(_ value: String) -> String {
        String(value.lowercased().map { char -> Character in
            char == "." || char == "_" || char == " " ? "-" : char
        })
    }

    /// Resolves a model string from a CLI log to its catalog entry. The longest
    /// matching id wins, and an id must match as a whole name, so an unknown
    /// future model (e.g. `claude-opus-4-9`) returns nil — reported as unpriced
    /// and refetched — instead of being priced as its nearest older family.
    func model(for rawModel: String?) -> Model? {
        guard let rawModel else { return nil }
        let text = Self.normalize(rawModel.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return nil }
        let lastComponent = text.split(separator: "/").last.map(String.init) ?? text
        if let target = aliases?.first(where: { alias, _ in
            let key = Self.normalize(alias)
            return key == text || key == lastComponent
        })?.value {
            return models.first { $0.id == target }
        }
        var best: (model: Model, length: Int)?
        for model in models {
            let mode = model.match ?? defaultMatch ?? .name
            for pattern in ([model.id] + (model.aliases ?? [])).map(Self.normalize) {
                guard pattern.count > (best?.length ?? 0) else { continue }
                let matched: Bool
                switch mode {
                case .name:   matched = Self.contains(text, name: pattern)
                case .exact:  matched = lastComponent == pattern
                case .prefix: matched = lastComponent == pattern || lastComponent.hasPrefix(pattern + "-")
                }
                if matched { best = (model, pattern.count) }
            }
        }
        return best?.model
    }

    private static func contains(_ text: String, name: String) -> Bool {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: name, range: searchStart..<text.endIndex) {
            let startsAtBoundary = range.lowerBound == text.startIndex
                || "-/".contains(text[text.index(before: range.lowerBound)])
            if startsAtBoundary, endsAtBoundary(text[range.upperBound...]) { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    /// What may follow a model name: nothing, a context suffix (`[1m]`), a
    /// Vertex `@date`, a Bedrock `:0`, a dated snapshot (`-20251001`), a
    /// version (`-v1`), or `-latest`.
    private static func endsAtBoundary(_ rest: Substring) -> Bool {
        guard let first = rest.first else { return true }
        if "[@:".contains(first) { return true }
        guard first == "-" else { return false }
        let tail = rest.dropFirst()
        if tail.hasPrefix("latest") { return true }
        let date = tail.prefix(8)
        if date.count == 8, date.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        if tail.first == "v", let digit = tail.dropFirst().first, digit.isASCII, digit.isNumber { return true }
        return false
    }
}

/// Holds one tool's active catalog: the higher revision of the bundled copy,
/// the last fetched copy cached on disk, and a fresh fetch from GitHub.
/// Refreshes daily, and early (throttled) when a log shows an unpriced model or
/// the CLI rejects a warm-up model. Thread-safe: `LocalUsageProvider` reads it
/// from a detached task.
final class ModelCatalogStore: @unchecked Sendable {
    static let claude = ModelCatalogStore(tool: .claude)
    static let codex = ModelCatalogStore(tool: .codex)

    static func shared(for tool: ToolID) -> ModelCatalogStore {
        switch tool {
        case .claude: return claude
        case .codex:  return codex
        }
    }

    static func resourceName(for tool: ToolID) -> String { "\(tool.rawValue)-models" }

    static func defaultRemoteURL(for tool: ToolID) -> URL {
        URL(string: "https://raw.githubusercontent.com/bcanozgur/quota-warmer/main/Sources/QuotaWarmer/Resources/\(resourceName(for: tool)).json")!
    }

    static func defaultCacheURL(for tool: ToolID) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("QuotaWarmer", isDirectory: true)
            .appendingPathComponent("\(resourceName(for: tool)).json")
    }

    let tool: ToolID
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let cacheURL: URL?
    private let remoteURL: URL
    private var current: ModelCatalog?
    private var currentSource = "none"
    private var isRefreshing = false
    private var reportedUnpricedModels = Set<String>()

    /// Regression tests turn this off so nothing reaches the network.
    var remoteRefreshEnabled = true
    let refreshInterval: TimeInterval = 24 * 3600
    let earlyRefreshInterval: TimeInterval = 3600
    private let maxDownloadBytes = 256 * 1024

    private var lastRefreshKey: String { "modelCatalog.\(tool.rawValue).lastRefreshAttempt" }
    private var workingWarmupModelKey: String { "modelCatalog.\(tool.rawValue).workingWarmupModel" }
    private var workingWarmupRevisionKey: String { "modelCatalog.\(tool.rawValue).workingWarmupRevision" }

    /// The app's store: bundled resource, Application Support cache, GitHub.
    convenience init(tool: ToolID) {
        self.init(
            tool: tool,
            bundle: .main,
            cacheURL: Self.defaultCacheURL(for: tool),
            remoteURL: Self.defaultRemoteURL(for: tool),
            defaults: .standard
        )
    }

    /// `bundle`/`cacheURL` nil skip that source (tests use isolated stores).
    init(tool: ToolID, bundle: Bundle?, cacheURL: URL?, remoteURL: URL, defaults: UserDefaults) {
        self.tool = tool
        self.cacheURL = cacheURL
        self.remoteURL = remoteURL
        self.defaults = defaults
        if let url = bundle?.url(forResource: Self.resourceName(for: tool), withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let bundled = try? ModelCatalog.decode(data) {
            adopt(bundled, source: "bundled")
        }
        if let cacheURL = self.cacheURL,
           let data = try? Data(contentsOf: cacheURL),
           let cached = try? ModelCatalog.decode(data) {
            adopt(cached, source: "cache")
        }
    }

    var catalog: ModelCatalog? {
        lock.withLock { current }
    }

    var summary: String {
        lock.withLock {
            guard let current else { return "none" }
            return "rev \(current.revision) (\(currentSource))"
        }
    }

    /// Installs `candidate` when it is at least as new as the active catalog.
    @discardableResult
    func adopt(_ candidate: ModelCatalog, source: String) -> Bool {
        lock.withLock {
            if let current, candidate.revision < current.revision { return false }
            current = candidate
            currentSource = source
            return true
        }
    }

    // MARK: Warm-up model

    /// Warm-up models in the order to try. The model that last worked moves to
    /// the front while the catalog revision it worked under is still active, so
    /// a retired first entry costs one failed attempt per catalog, not per warm.
    var warmupModels: [String] {
        guard let catalog else { return [tool.defaultWarmupModel] }
        var models = catalog.warmup.models
        if defaults.integer(forKey: workingWarmupRevisionKey) == catalog.revision,
           let working = defaults.string(forKey: workingWarmupModelKey),
           let index = models.firstIndex(of: working), index > 0 {
            models.remove(at: index)
            models.insert(working, at: 0)
        }
        return models
    }

    func rememberWorkingWarmupModel(_ model: String) {
        guard let catalog else { return }
        let previous = defaults.string(forKey: workingWarmupModelKey)
        defaults.set(model, forKey: workingWarmupModelKey)
        defaults.set(catalog.revision, forKey: workingWarmupRevisionKey)
        if previous != model {
            DiagnosticLogger.append("warmup_model_selected tool=\(tool.rawValue) model=\(model) catalog=\(summary)")
        }
    }

    // MARK: Unpriced models

    /// Called with model ids from local logs that the catalog cannot price.
    /// Each id is logged once per launch and triggers one early refresh.
    func reportUnpricedModels(_ models: Set<String>) {
        let fresh: [String] = lock.withLock {
            let fresh = models.subtracting(reportedUnpricedModels).sorted()
            reportedUnpricedModels.formUnion(fresh)
            return fresh
        }
        guard !fresh.isEmpty else { return }
        DiagnosticLogger.append("pricing_unknown_model tool=\(tool.rawValue) models=\(fresh.joined(separator: ",")) catalog=\(summary)")
        Task { await refreshIfNeeded(early: true) }
    }

    // MARK: Refresh

    /// Fetches the catalog from GitHub when the last attempt is older than a day
    /// (`early`: older than an hour). Returns true when a newer revision was
    /// installed.
    @discardableResult
    func refreshIfNeeded(early: Bool = false, now: Date = Date()) async -> Bool {
        guard remoteRefreshEnabled,
              beginRefresh(minimumAge: early ? earlyRefreshInterval : refreshInterval, now: now) else {
            return false
        }
        defer { endRefresh() }

        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                DiagnosticLogger.append("model_catalog_refresh_failed tool=\(tool.rawValue) reason=http\(status)")
                return false
            }
            guard data.count <= maxDownloadBytes else {
                DiagnosticLogger.append("model_catalog_refresh_failed tool=\(tool.rawValue) reason=tooLarge")
                return false
            }
            let remote = try ModelCatalog.decode(data)
            let previous = catalog?.revision ?? 0
            guard remote.revision > previous, adopt(remote, source: "remote") else { return false }
            writeCache(data)
            DiagnosticLogger.append("model_catalog_updated tool=\(tool.rawValue) revision=\(previous)->\(remote.revision)")
            // Re-report anything the new revision still cannot price.
            lock.withLock { reportedUnpricedModels.removeAll() }
            return true
        } catch {
            DiagnosticLogger.append("model_catalog_refresh_failed tool=\(tool.rawValue) reason=\(error.localizedDescription)")
            return false
        }
    }

    /// Single-flight + throttle. The attempt time is recorded up front so a
    /// failing endpoint is retried on the same schedule, not on every call.
    private func beginRefresh(minimumAge: TimeInterval, now: Date) -> Bool {
        lock.withLock {
            let lastAttempt = defaults.object(forKey: lastRefreshKey) as? Date
            if isRefreshing || (lastAttempt.map { now.timeIntervalSince($0) < minimumAge } ?? false) {
                return false
            }
            isRefreshing = true
            defaults.set(now, forKey: lastRefreshKey)
            return true
        }
    }

    private func endRefresh() {
        lock.withLock { isRefreshing = false }
    }

    private func writeCache(_ data: Data) {
        guard let cacheURL else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}
