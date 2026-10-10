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

    /// A cell that produced diagnostics (`built`/`build_failed`) but also left unreadable `.dia` files
    /// has an incomplete diagnostic set and must not be reported as a result.
    public static func truncatedDiaInvalidatesCell(outcome: CellOutcome) -> Bool {
        outcome == .built || outcome == .buildFailed
    }

    /// Markers of a SwiftPM dependency-resolution failure. Deliberately specific: "unable to resolve
    /// module dependency: 'UIKit'" is a *compile* failure (an iOS-only package on macOS) and an earlier,
    /// looser "unable to resolve" marker misfiled three such cells as resolve failures.
    static let resolutionFailureMarkers = [
        "dependencies could not be resolved",
        "failed to clone",
        "could not resolve",
        "failed to resolve",
        "resolved file is required",
        "out-of-date",
        "invalid manifest",
        "failed to retrieve manifest",
    ]

    /// The first compile command in the verbose build log that carries the census flags: the
    /// resolved frontend invocation (F7). The manifest compile precedes it and lacks the flags, so
    /// "first `-module-name` line" would record the wrong command. Keyed on `-strict-concurrency=`,
    /// not `=complete`, so `minimal-v5` cells (ADR 0007) are recognised too.
    public static func frontendInvocationSample(in log: String) -> String? {
        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(" -module-name "), line.contains("-strict-concurrency=") else { continue }
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

    /// The remainder of the first line starting with `prefix` (`sw_vers`'s `BuildVersion:`,
    /// `xcodebuild -version`'s `Build version`). Nil on Linux, where neither is present.
    public static func value(forPrefix prefix: String, inVersionOutput text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix(prefix) {
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    public static func toolchainVersion(inVersionOutput text: String) -> String? {
        text.split(separator: "\n").first.map { String($0) }
    }
}

extension OutcomeClassifier {
    /// Re-derives a committed cell's outcome from its stored raw log and exit code, without rebuilding.
    /// Timeouts and infra errors are kept: they cannot be recovered from the log alone.
    public static func reclassify(_ record: CellRecord, log: String) -> CellOutcome {
        switch record.outcome {
        case .timeout, .infraError: return record.outcome
        default:
            guard let exit = record.exitCode else { return record.outcome }
            return classify(exitCode: Int32(exit), timedOut: false, log: log)
        }
    }
}
