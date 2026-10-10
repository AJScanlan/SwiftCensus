import CensusCore
import DiagParse
import Foundation

/// Turns a finished build's raw output directory into a committed cell: classifies the outcome, parses
/// the `.dia` tree, and writes `diagnostics.json`, `build.log.gz` and `dia.tar.gz`. Shared by every
/// platform runner so a Linux cell and a macOS cell are interpreted identically.
///
/// `raw` must contain `build.log`, `exit-code`, `env.txt` and optionally `dia.tar.gz`.
enum CellIngest {
    static func ingest(
        raw: URL, extracted: URL, cellDir: URL, timedOut: Bool, packageRoot: String,
        store: RunStore, record: inout CellRecord
    ) async throws {
        let fm = FileManager.default
        let log = (try? String(contentsOf: raw.appendingPathComponent("build.log"), encoding: .utf8)) ?? ""
        let exit = (try? String(contentsOf: raw.appendingPathComponent("exit-code"), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let env = (try? String(contentsOf: raw.appendingPathComponent("env.txt"), encoding: .utf8)) ?? ""

        record.exitCode = exit.map(Int.init)
        record.outcome = OutcomeClassifier.classify(exitCode: exit ?? -1, timedOut: timedOut, log: log)
        record.frontendInvocationSample = OutcomeClassifier.frontendInvocationSample(in: log)
        record.toolchainVersion = OutcomeClassifier.toolchainVersion(inVersionOutput: env)
        record.targetTriple = OutcomeClassifier.targetTriple(inVersionOutput: env)
        record.osBuild = OutcomeClassifier.value(forPrefix: "BuildVersion:", inVersionOutput: env)
        record.xcodeBuild = OutcomeClassifier.value(forPrefix: "Build version", inVersionOutput: env)

        // Parse whatever diagnostics exist, whatever the outcome: a failed build is still data.
        let diaTar = raw.appendingPathComponent("dia.tar.gz")
        var diagnostics: [DiagnosticRecord] = []
        if fm.fileExists(atPath: diaTar.path) {
            try await Shell.check("tar", ["-xzf", diaTar.path, "-C", extracted.path])
            let files = DiagParse.enumerateDia(under: extracted)
            let parsed = DiagParse.parse(diaFiles: files, packageRoot: packageRoot)
            diagnostics = parsed.records
            record.diaFilesFound = parsed.diaFilesFound
            record.diaFilesUnreadable = parsed.unreadable.count
            record.diaFilesEmpty = parsed.emptyDiaFiles
            if !parsed.unreadable.isEmpty {
                record.note = "unreadable .dia: " + parsed.unreadable.map(\.path).joined(separator: ", ")
                // A non-empty .dia that will not parse is corrupt output, so the diagnostic set is incomplete
                // and the cell is not a measurement. (Empty .dia files are normal and not counted here.)
                if OutcomeClassifier.truncatedDiaInvalidatesCell(outcome: record.outcome) {
                    record.outcome = .infraError
                    record.note = "corrupt .dia (non-empty but unparseable); the diagnostic set is incomplete; " + (record.note ?? "")
                }
            }
        }
        record.tally = DiagnosticTally(records: diagnostics)

        try fm.createDirectory(at: cellDir, withIntermediateDirectories: true)
        try store.write(diagnostics, to: cellDir.appendingPathComponent("diagnostics.json"))
        // `-n` omits the timestamp and name from the gzip header so identical logs gzip identically.
        let gz = cellDir.appendingPathComponent("build.log.gz")
        try await Shell.check("/bin/sh", [
            "-c", "gzip -n -9 -c \(CellRunner.quote(raw.appendingPathComponent("build.log").path)) > \(CellRunner.quote(gz.path))",
        ])
        if fm.fileExists(atPath: diaTar.path) {
            try? fm.removeItem(at: cellDir.appendingPathComponent("dia.tar.gz"))
            try fm.copyItem(at: diaTar, to: cellDir.appendingPathComponent("dia.tar.gz"))
        }
    }
}
