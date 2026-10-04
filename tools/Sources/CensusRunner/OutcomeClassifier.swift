import CensusCore
import Foundation

public enum OutcomeClassifier {
    /// Decides how a cell ended from the build exit code and verbose log. Pure, so it is testable
    /// without a compiler. Infra failures (Docker, network) are decided by the caller, not here.
    public static func classify(exitCode: Int32, timedOut: Bool, log: String) -> CellOutcome {
        if timedOut { return .timeout }
        if exitCode == 0 { return .built }
        // 137 = SIGKILL, which in a memory-limited container is the OOM killer: the instrument ran out
        // of memory, the package did not fail. Recorded as infra so it is re-run with a larger limit.
        if exitCode == 137 { return .infraError }
        let lower = log.lowercased()
        if lower.contains("is using swift tools version") && lower.contains("but the installed version is") {
            return .unsupportedToolsVersion
        }
        let compileStarted = compileStarted(in: log)
        if !compileStarted && resolutionFailureMarkers.contains(where: lower.contains) {
            return .resolveFailed
        }
        return .buildFailed
    }

    static let resolutionFailureMarkers = [
        "dependencies could not be resolved",
        "failed to clone",
        "could not resolve",
        "failed to resolve",
        "resolved file is required",
        "out-of-date",
        "unable to resolve",
        "invalid manifest",
        "failed to retrieve manifest",
    ]

    /// The first compile command in the verbose build log that carries the census flags: the
    /// resolved frontend invocation (F7). The manifest compile precedes it and lacks the flags, so
    /// "first `-module-name` line" would record the wrong command.
    public static func frontendInvocationSample(in log: String) -> String? {
        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(" -module-name "), line.contains("-strict-concurrency=complete") else { continue }
            if line.contains("swiftc") || line.contains("swift-frontend") || line.contains("swift-driver") {
                return String(line.prefix(4000))
            }
        }
        return nil
    }

    /// Whether any package compile was attempted. Manifest evaluation also prints `-module-name`
    /// commands, so this keys on the census flags too.
    static func compileStarted(in log: String) -> Bool { frontendInvocationSample(in: log) != nil }

    /// `Target: aarch64-unknown-linux-gnu` from `swift --version`.
    public static func targetTriple(inVersionOutput text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("Target:") {
            return line.dropFirst("Target:".count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    public static func toolchainVersion(inVersionOutput text: String) -> String? {
        text.split(separator: "\n").first.map { String($0) }
    }
}
