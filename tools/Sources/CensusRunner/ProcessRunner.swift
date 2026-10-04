import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public struct ProcessError: Error, CustomStringConvertible {
    public var command: String
    public var result: ProcessResult
    public var description: String {
        "`\(command)` exited \(result.exitCode)\(result.timedOut ? " (timed out)" : ""): "
            + String(result.stderrString.suffix(600))
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var timedOut = false
    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
}

public enum Shell {
    /// Runs a process to completion, draining stdout/stderr concurrently so large output cannot
    /// deadlock the pipe. On timeout the process is terminated and `timedOut` is set.
    @discardableResult
    public static func run(
        _ executable: String, _ arguments: [String], currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        let box = ProcessBox()
        let out = Pipe(), err = Pipe()
        let outBuf = LockedData(), errBuf = LockedData()
        let p = box.process
        if executable.contains("/") {
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [executable] + arguments
        }
        p.currentDirectoryURL = currentDirectory
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { outBuf.append(d) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { errBuf.append(d) }
        }

        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outBuf.append(out.fileHandleForReading.readDataToEndOfFile())
                errBuf.append(err.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: ProcessResult(
                    exitCode: proc.terminationStatus, stdout: outBuf.snapshot(),
                    stderr: errBuf.snapshot(), timedOut: box.didTimeOut))
            }
            do {
                try p.run()
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: error)
                return
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if box.process.isRunning {
                        box.markTimedOut()
                        box.process.terminate()
                    }
                }
            }
        }
    }

    /// Like `run`, but throws `ProcessError` unless the process exits 0.
    @discardableResult
    public static func check(
        _ executable: String, _ arguments: [String], currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        let r = try await run(executable, arguments, currentDirectory: currentDirectory, timeout: timeout)
        guard r.succeeded else {
            throw ProcessError(command: ([executable] + arguments).joined(separator: " "), result: r)
        }
        return r
    }
}
