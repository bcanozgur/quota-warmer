import Foundation

enum WarmupError: LocalizedError {
    case cliNotFound(String)
    case exitCode(Int32)
    case timeout

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let cmd): return "CLI not found: \(cmd)"
        case .exitCode(let code):   return "Process exited with code \(code)"
        case .timeout:              return "Warmup timed out after 60s"
        }
    }
}

struct WarmupResult {
    let date: Date
    let output: String
}

class WarmupRunner {

    func warmup(_ tool: ToolID) async throws -> WarmupResult {
        let cliName = tool == .claude ? "claude" : "codex"
        guard await cliExists(cliName) else {
            throw WarmupError.cliNotFound(cliName)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", tool.warmupCommand]

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError  = errPipe

            var resumed = false

            let timeoutWork = DispatchWorkItem {
                process.terminate()
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: WarmupError.timeout)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeoutWork)

            process.terminationHandler = { p in
                timeoutWork.cancel()
                guard !resumed else { return }
                resumed = true

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let combined = [outData, errData]
                    .compactMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                if p.terminationStatus == 0 {
                    continuation.resume(returning: WarmupResult(date: Date(), output: combined.isEmpty ? "(no output)" : combined))
                } else {
                    continuation.resume(throwing: WarmupError.exitCode(p.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                timeoutWork.cancel()
                if !resumed {
                    resumed = true
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
}
