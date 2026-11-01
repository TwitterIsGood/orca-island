import Darwin
import Foundation

/// Synchronous, bounded CLI execution. Call only from a background queue.
enum OrcaCommandRunner {
    static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let installedPaths = [
            "/Applications/Orca.app/Contents/Resources/bin/orca",
            "\(home)/Applications/Orca.app/Contents/Resources/bin/orca",
            "/usr/local/bin/orca",
            "/opt/homebrew/bin/orca",
            "\(home)/.local/bin/orca"
        ]
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/orca" }
        return (installedPaths + searchPaths)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    @discardableResult
    static func run(_ arguments: [String], timeout: TimeInterval = 3) -> Data? {
        guard let executable = executableURL() else { return nil }
        return execute(executable, arguments: arguments, timeout: timeout)
    }

    static func runHelper(_ arguments: [String], timeout: TimeInterval = 12) -> Data? {
        guard let cli = executableURL()?.resolvingSymlinksInPath() else { return nil }
        let contents = cli.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let electron = contents.appendingPathComponent("MacOS/Orca")
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("orca-snapshot.cjs"),
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                            .deletingLastPathComponent().deletingLastPathComponent()
                            .deletingLastPathComponent().appendingPathComponent("scripts/orca-snapshot.cjs")]
        guard FileManager.default.isExecutableFile(atPath: electron.path),
              let helper = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return execute(electron, arguments: [helper.path] + arguments, timeout: timeout, nodeMode: true)
    }

    private static func execute(_ executable: URL, arguments: [String], timeout: TimeInterval,
                                nodeMode: Bool = false) -> Data? {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { _ in exited.signal() }

        // A GUI launch has a minimal PATH; the Orca shell launcher still needs bash.
        var environment = ProcessInfo.processInfo.environment
        // Never inherit this task's terminal/workspace/remote selectors into a desktop-wide read.
        environment = environment.filter { !$0.key.hasPrefix("ORCA_") }
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_REPL_EXTERNAL_MODULE")
        if nodeMode { environment["ELECTRON_RUN_AS_NODE"] = "1" }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:" + (environment["PATH"] ?? "")
        process.environment = environment

        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        defer {
            for handle in handles { try? handle.close() }
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
        }
        for handle in handles {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0,
                  fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                return nil
            }
        }

        do {
            try process.run()
        } catch {
            return nil
        }
        // Closing our writer copies lets the readers reach EOF when the child exits.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        var data = Data()
        var discardedErrors = Data()
        var truncated = false
        var errorsTruncated = false
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.1, timeout)
        while true {
            drain(output.fileHandleForReading, into: &data, limit: 8 * 1024 * 1024, truncated: &truncated)
            drain(errors.fileHandleForReading, into: &discardedErrors, limit: 0, truncated: &errorsTruncated)
            if exited.wait(timeout: .now() + 0.02) == .success { break }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                process.terminate()
                if exited.wait(timeout: .now() + 0.25) == .timedOut {
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                    _ = exited.wait(timeout: .now() + 0.25)
                }
                return nil
            }
        }

        drain(output.fileHandleForReading, into: &data, limit: 8 * 1024 * 1024, truncated: &truncated)
        drain(errors.fileHandleForReading, into: &discardedErrors, limit: 0, truncated: &errorsTruncated)
        guard process.terminationStatus == 0, !truncated else { return nil }
        return data
    }

    private static func drain(_ handle: FileHandle, into data: inout Data, limit: Int, truncated: inout Bool) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // Bound each pass even if a child continuously emits output.
        for _ in 0..<32 {
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            guard count > 0 else { return }
            let retained = min(count, max(0, limit - data.count))
            if retained > 0 { data.append(contentsOf: buffer.prefix(retained)) }
            if retained < count { truncated = true }
        }
    }
}
