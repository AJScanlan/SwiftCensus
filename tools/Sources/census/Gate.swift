import ArgumentParser
import CensusCore
import CensusRunner
import Foundation

struct Gate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "ROADMAP §4 decision gates, evaluated from committed runs.",
        subcommands: [G2Command.self])
}

extension Gate {
    struct G2Command: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "g2",
            abstract: "G2 (ADR 0007 D8, scored per ADR 0008): do the 30 S-emit entries emit on Linux 6.4?",
            discussion: "Exit 0: passes. Exit 1: fails. Exit 2: not evaluable (a 6.4 S-emit cell missing or infra_error, "
                + "a non-Linux S-emit cell, or a population other than 30). Score the first pass, never the re-run.")

        @OptionGroup var corpus: CorpusOptions
        @Argument(help: "Linux run directory, e.g. runs/2026-10-11.") var runDirectory: String
        @Option(name: .long, help: "Also write the report as JSON here, e.g. runs/2026-10-11/g2.json.") var json: String?

        func run() async throws {
            let report = G2.evaluate(manifest: try corpus.paths.loadManifest(),
                                     cells: try RunStore(root: URL(fileURLWithPath: runDirectory)).loadCells())
            for line in G2.render(report) { print(line) }
            if let json { try RunStore(root: URL(fileURLWithPath: ".")).write(report, to: URL(fileURLWithPath: json)) }
            switch report.verdict {
            case .pass: return
            case .fail: throw ExitCode.failure
            case .notEvaluable: throw ExitCode(2)
            }
        }
    }
}
