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
        guard await cliExists(cliName) else {
            throw WarmupError.cliNotFound(cliName)
        }
        let workspaceURL = try warmupWorkspaceURL()

        do {
            return try await runWarmupCommand(tool.warmupCommand, cliName: cliName, workspaceURL: workspaceURL)
        } catch WarmupError.exitCode where tool.fallbackWarmupCommand != nil {
            let result = try await runWarmupCommand(tool.fallbackWarmupCommand!, cliName: cliName, workspaceURL: workspaceURL)
            return WarmupResult(
                date: result.date,
                command: result.command,
                output: "Primary warmup model was unavailable; retried with configured Codex default model.\n\(result.output)"
            )
        }
    }

    private func runWarmupCommand(_ command: String, cliName: String, workspaceURL: URL) async throws -> WarmupResult {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = workspaceURL

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
        return !(await cliExists(name))
    }

    private func cliExists(_ name: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "which \(name)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError  = FileHandle.nullDevice
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus == 0)
            }
            try? process.run()
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
