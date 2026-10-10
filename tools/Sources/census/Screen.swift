import ArgumentParser
import CensusCore
import CensusRunner
import Foundation
import Yams

/// Layout of one screen (ADR 0007): `<root>/<id>/{candidates.yaml, resolved/, results.json, emitters.csv}`.
/// Runs go under `runs/<id>-macos-bN` and `runs/<id>-macos-verify`; driver state under `work/screen-state/<id>/`.
struct ScreenPaths {
    var root: String
    var id: String

    var directory: URL { URL(fileURLWithPath: root).appendingPathComponent(id) }
    var candidates: URL { directory.appendingPathComponent("candidates.yaml") }
    var resolved: URL { directory.appendingPathComponent("resolved") }

    func loadCandidates() throws -> CorpusManifest {
        try YAMLDecoder().decode(CorpusManifest.self, from: String(contentsOf: candidates, encoding: .utf8))
    }
}

struct ScreenOptions: ParsableArguments {
    @Argument(help: "Screen id, ending in its date, e.g. screen-2026-10-10.") var id: String
    @Option(name: .long, help: "Directory holding screen directories.") var root = "screens"
    var paths: ScreenPaths { ScreenPaths(root: root, id: id) }
}
