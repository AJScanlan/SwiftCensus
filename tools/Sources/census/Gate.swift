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
            discussion: "Exit 0: passes. Exit 1: fails. Exit 2: not evaluable (a 6.4 S-emit cell missing, infra_error or "
                + "from an unpinned image, a non-Linux S-emit cell, a population other than 30, a manifest other than the "
                + "run's) or the gate could not read or write its inputs. Exit 1 therefore always means G2 FAIL. "
                + "Score the first pass, never the re-run.")

        @OptionGroup var corpus: CorpusOptions
        @Argument(help: "Linux run directory, e.g. runs/2026-10-11.") var runDirectory: String
        @Option(name: .long, help: "Also write the report as JSON here, e.g. runs/2026-10-11/g2.json.") var json: String?

        func run() async throws {
            let report: G2.Report
            // Any I/O failure is "not evaluable", never exit 1, which is reserved for a G2 FAIL.
            do {
                let run = URL(fileURLWithPath: runDirectory)
                let recorded = try JSONDecoder().decode(
                    RunManifest.self, from: Data(contentsOf: run.appendingPathComponent("run.json")))
                report = G2.evaluate(manifest: try corpus.paths.loadManifest(), cells: try RunStore(root: run).loadCells(),
                                     manifestSHA256: try MatrixRun.sha256Hex(of: corpus.paths.corpus),
                                     runManifestSHA256: recorded.corpusManifestSHA256)
                for line in G2.render(report) { print(line) }
                if let json { try RunStore(root: URL(fileURLWithPath: ".")).write(report, to: URL(fileURLWithPath: json)) }
            } catch {
                print("G2 NOT EVALUABLE: \(error)")
                throw ExitCode(2)
            }
            switch report.verdict {
            case .pass: return
            case .fail: throw ExitCode.failure
            case .notEvaluable: throw ExitCode(2)
            }
        }
    }
}
