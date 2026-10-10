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

    var results: URL { directory.appendingPathComponent("results.json") }
    var emitters: URL { directory.appendingPathComponent("emitters.csv") }
    var state: URL { URL(fileURLWithPath: "work/screen-state").appendingPathComponent(id) }
    func runId(batch: Int) -> String { "\(id)-macos-b\(batch)" }
    var verifyRunId: String { "\(id)-macos-verify" }
    /// The screen as a corpus: its candidates and their vendored graphs, so `Paths`-based code runs unchanged.
    var corpusPaths: Paths { Paths(corpus: candidates, resolved: resolved) }

    func hasResolved(_ p: CorpusPackage) -> Bool {
        FileManager.default.fileExists(atPath: resolved.appendingPathComponent("\(p.slug).resolved").path)
    }

    /// `census resolve --allow-failures` records these; each becomes an `unresolvable` result. Missing file means
    /// none; a corrupt file throws, so it can never silently turn unresolvable candidates into "missing" ones.
    func resolveFailures() throws -> [String: String] {
        try loadJSON([String: String].self, from: resolved.appendingPathComponent("failures.json"), default: [:])
    }

    func loadResults() throws -> [ScreenResult] {
        try JSONDecoder().decode([ScreenResult].self, from: Data(contentsOf: results))
    }
}

struct ScreenOptions: ParsableArguments {
    @Argument(help: "Screen id, ending in its date, e.g. screen-2026-10-10.") var id: String
    @Option(name: .long, help: "Directory holding screen directories.") var root = "screens"
    var paths: ScreenPaths { ScreenPaths(root: root, id: id) }
}

struct ScreenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "The macOS screen that selects S-emit by measurement (ADR 0007).",
        subcommands: [Batch.self, Batches.self])
}

/// The packages a pass works through: every candidate for pass 1, the pass-1 emitters for the verify pass.
private func pool(_ sp: ScreenPaths, verify: Bool) throws -> [CorpusPackage] {
    let candidates = try sp.loadCandidates().packages
    return verify ? Screen.verifyPackages(results: try sp.loadResults(), candidates: candidates) : candidates
}

extension ScreenCommand {
    struct Batch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Screen one batch of 50 in one fresh guest clone (§5.2).",
            discussion: """
            Builds strict-complete-v5 for the batch, then minimal-v5 only where the complete cell built with at least \
            one primary diagnostic. Resumable: cells already present are skipped, and a batch with every cell present \
            boots no guest. Exits 3 if infra_error cells remain.
            """)

        @OptionGroup var screen: ScreenOptions
        @Argument(help: "Batch number, 1-based.") var batch: Int
        @Flag(name: .long, help: "Re-run the pass-1 emitters into <id>-macos-verify (§5.6).") var verify = false
        @Flag(name: .long, help: "Delete this batch's infra_error cells first so they run again (the one retry).") var retryInfra = false
        @Option(name: .long, help: "Per-cell timeout, minutes.") var timeoutMinutes = 45

        func run() async throws {
            let sp = screen.paths
            let members = Screen.batch(batch, of: try pool(sp, verify: verify))
            guard !members.isEmpty else { throw ValidationError("batch \(batch) is empty") }
            let ids = Set(members.map(\.id))
            // Unresolvable candidates have no vendored graph and are never built (F1); collect records them.
            let buildable = members.filter(sp.hasResolved)
            let paths = sp.corpusPaths
            let runId = verify ? sp.verifyRunId : sp.runId(batch: batch)
            let store = RunStore(root: paths.runDirectory(runId))
            let tc = Screen.toolchain.name

            if retryInfra {
                for cell in try store.loadCells().values where cell.record.outcome == .infraError && ids.contains(cell.record.packageId) {
                    print("retrying \(cell.record.mode.rawValue) \(cell.record.packageId)")
                    try FileManager.default.removeItem(at: cell.directory)
                }
            }

            func pendingMinimal() throws -> [CorpusPackage] {
                let cells = try store.loadCells()
                return buildable.filter { p in
                    guard let c = cells[RunStore.CellKey(toolchain: tc, mode: .strictCompleteV5, packageId: p.id)] else { return false }
                    return Screen.needsMinimal(c) && cells[RunStore.CellKey(toolchain: tc, mode: .minimalV5, packageId: p.id)] == nil
                }
            }

            let completePending = buildable.filter { !store.hasCell(toolchain: tc, mode: .strictCompleteV5, slug: $0.slug) }
            if completePending.isEmpty, try pendingMinimal().isEmpty {
                print("batch \(batch) (\(runId)): every cell present")
            } else {
                // Fetch sources before the guest boots: two cells of one package must not race a clone.
                for p in buildable { try await paths.sources.ensure(p) }
                try FileManager.default.createDirectory(at: paths.scratch, withIntermediateDirectories: true)
                try await withMacGuest(runId: runId, paths: paths, store: store, timeoutMinutes: timeoutMinutes) { runner in
                    await MatrixRun.execute(cells: Screen.cells(buildable, mode: .strictCompleteV5), runner: runner, jobs: 1,
                                            force: false, imageID: { _ in GuestVM.restoreImageDigest() }) { print($0); fflush(stdout) }
                    // Early exit (§5.2 step 4): no primary diagnostic under complete means count 0, no second build.
                    let minimal = try pendingMinimal()
                    await MatrixRun.execute(cells: Screen.cells(minimal, mode: .minimalV5), runner: runner, jobs: 1,
                                            force: false, imageID: { _ in GuestVM.restoreImageDigest() }) { print($0); fflush(stdout) }
                }
            }

            let infra = try store.loadCells().values.filter { $0.record.outcome == .infraError && ids.contains($0.record.packageId) }
            if !infra.isEmpty {
                print("\(infra.count) infra_error cell(s) remain in batch \(batch)")
                throw ExitCode(3)
            }
        }
    }

    struct Batches: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print how many batches a pass has (for scripts/screen-drive.sh).")
        @OptionGroup var screen: ScreenOptions
        @Flag(name: .long, help: "Count the verify pass (pass-1 emitters) instead of pass 1.") var verify = false

        func run() async throws {
            print(Screen.batchCount(try pool(screen.paths, verify: verify).count))
        }
    }
}
