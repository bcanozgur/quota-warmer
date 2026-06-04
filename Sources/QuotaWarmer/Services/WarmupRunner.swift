import Foundation

enum WarmupError: LocalizedError {
    case cliNotFound(String)
    case exitCode(Int32)
    case timeout
    case workspaceUnavailable

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let cmd): return "CLI not found: \(cmd)"
        case .exitCode(let code):   return "Process exited with code \(code)"
        case .timeout:              return "Warmup timed out after 60s"
        case .workspaceUnavailable: return "Could not prepare isolated warmup directory"
        }
    }
}

struct WarmupResult {
    let date: Date
    let command: String
    let output: String
}

class WarmupRunner {

    func warmup(_ tool: ToolID) async throws -> WarmupResult {
        let cliName = tool == .claude ? "claude" : "codex"
        guard let cliURL = await resolveCLI(named: cliName) else {
            throw WarmupError.cliNotFound(cliName)
        }
        let workspaceURL = try warmupWorkspaceURL()
        let pathPrefix = cliURL.deletingLastPathComponent().path

        do {
            return try await runWarmupCommand(tool.warmupCommand, cliName: cliName, pathPrefix: pathPrefix, workspaceURL: workspaceURL)
        } catch WarmupError.exitCode where tool.fallbackWarmupCommand != nil {
            let result = try await runWarmupCommand(tool.fallbackWarmupCommand!, cliName: cliName, pathPrefix: pathPrefix, workspaceURL: workspaceURL)
            return WarmupResult(
                date: result.date,
                command: result.command,
                output: "Primary warmup model was unavailable; retried with configured Codex default model.\n\(result.output)"
            )
        }
    }

    private func runWarmupCommand(_ command: String, cliName: String, pathPrefix: String, workspaceURL: URL) async throws -> WarmupResult {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = workspaceURL
            process.environment = environment(prependingPath: pathPrefix)
            // The CLI (e.g. `codex exec`) reads stdin when it is not a tty and a
            // prompt is also provided. A GUI agent app inherits an arbitrary
            // stdin that can block forever, turning a fast warm-up into a 60s
            // timeout — which throws `.timeout` and never reaches the exit-code
            // fallback. Feed EOF immediately so the run is deterministic.
            process.standardInput = FileHandle.nullDevice

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError  = errPipe

            let gate = WarmupContinuationGate()

            let timeoutWork = DispatchWorkItem {
                process.terminate()
                if gate.tryResume() {
                    continuation.resume(throwing: WarmupError.timeout)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeoutWork)

            process.terminationHandler = { p in
                timeoutWork.cancel()
                guard gate.tryResume() else { return }

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let combined = [outData, errData]
                    .compactMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                if p.terminationStatus == 0 {
                    continuation.resume(returning: WarmupResult(date: Date(), command: command, output: combined.isEmpty ? "(no output)" : combined))
                } else {
                    continuation.resume(throwing: WarmupError.exitCode(p.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                timeoutWork.cancel()
                if gate.tryResume() {
                    continuation.resume(throwing: WarmupError.cliNotFound(cliName))
                }
            }
        }
    }

    func cliMissing(_ tool: ToolID) async -> Bool {
        let name = tool == .claude ? "claude" : "codex"
        return await resolveCLI(named: name) == nil
    }

    private func resolveCLI(named name: String) async -> URL? {
        for url in candidateCLIURLs(named: name) {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        if let shellURL = await commandPath(named: name) {
            return shellURL
        }

        return nil
    }

    private func commandPath(named name: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v \(name)"]
            process.environment = environment(prependingPath: nil)

            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError  = FileHandle.nullDevice
            process.terminationHandler = { p in
                guard p.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty {
                    continuation.resume(returning: URL(fileURLWithPath: path))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private func candidateCLIURLs(named name: String) -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var dirs: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".npm-global/bin"),
            home.appendingPathComponent(".bun/bin")
        ]

        let nvmRoot = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            dirs.append(contentsOf: versions.map { $0.appendingPathComponent("bin") })
        }

        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) }
        dirs.append(contentsOf: pathDirs)

        var seen = Set<String>()
        return dirs.compactMap { dir in
            let candidate = dir.appendingPathComponent(name)
            guard seen.insert(candidate.path).inserted else { return nil }
            return candidate
        }
    }

    private func environment(prependingPath pathPrefix: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var components: [String] = []
        if let pathPrefix, !pathPrefix.isEmpty {
            components.append(pathPrefix)
        }
        components.append(contentsOf: [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.bun/bin"
        ])
        if let existing = env["PATH"], !existing.isEmpty {
            components.append(existing)
        }
        env["PATH"] = uniquePath(components).joined(separator: ":")
        return env
    }

    private func uniquePath(_ components: [String]) -> [String] {
        var seen = Set<String>()
        return components.filter { component in
            guard !component.isEmpty else { return false }
            return seen.insert(component).inserted
        }
    }

    private func warmupWorkspaceURL() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("QuotaWarmerWarmup", isDirectory: true)
        let fileManager = FileManager.default

        do {
            if fileManager.fileExists(atPath: url.path) {
                let contents = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                for item in contents {
                    try fileManager.removeItem(at: item)
                }
            } else {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        } catch {
            throw WarmupError.workspaceUnavailable
        }
    }
}

private final class WarmupContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}
