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
        subcommands: [Batch.self, Batches.self, Collect.self, Status.self])
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
            boots no guest. Exits 3 if infra_error cells remain or the guest failed to boot.
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
            let failures = try sp.resolveFailures()
            let unaccounted = members.filter { !sp.hasResolved($0) && failures[$0.id] == nil }.map(\.id)
            guard unaccounted.isEmpty else {
                throw ValidationError("batch \(batch): \(unaccounted.joined(separator: ", ")) neither resolved nor recorded as unresolvable; run the resolve phase first")
            }
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
                do {
                    try await withMacGuest(runId: runId, paths: paths, store: store, timeoutMinutes: timeoutMinutes) { runner in
                        await MatrixRun.execute(cells: Screen.cells(buildable, mode: .strictCompleteV5), runner: runner, jobs: 1,
                                                force: false, imageID: { _ in GuestVM.restoreImageDigest() }) { print($0); fflush(stdout) }
                        // Early exit (§5.2 step 4): no primary diagnostic under complete means count 0, no second build.
                        let minimal = try pendingMinimal()
                        await MatrixRun.execute(cells: Screen.cells(minimal, mode: .minimalV5), runner: runner, jobs: 1,
                                                force: false, imageID: { _ in GuestVM.restoreImageDigest() }) { print($0); fflush(stdout) }
                    }
                } catch let boot as GuestBootError {
                    // Exit 3 is the driver's retry-once path. The guest never came up, so no cell was written.
                    print("\(boot)")
                    throw ExitCode(3)
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

    struct Collect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Merge the batch runs into results.json and emitters.csv, and print the denominator table (§5.5).")

        @OptionGroup var screen: ScreenOptions
        @Flag(name: .long, help: "Apply the verify pass (§5.6): emitters whose re-run differs become unstable.") var withVerify = false

        func run() async throws {
            let sp = screen.paths
            let candidates = try sp.loadCandidates().packages
            guard let asOf = Screen.date(fromScreenId: sp.id) else { throw ValidationError("screen id must end in YYYY-MM-DD") }
            let paths = sp.corpusPaths
            let failures = try sp.resolveFailures()
            let tc = Screen.toolchain.name
            func key(_ id: String, _ m: Mode) -> RunStore.CellKey { RunStore.CellKey(toolchain: tc, mode: m, packageId: id) }

            var cells: [RunStore.CellKey: RunStore.LoadedCell] = [:]
            for n in stride(from: 1, through: Screen.batchCount(candidates.count), by: 1) {
                for (k, cell) in try RunStore(root: paths.runDirectory(sp.runId(batch: n))).loadCells() {
                    guard cells.updateValue(cell, forKey: k) == nil else { throw ValidationError("cell \(k) appears in more than one batch run") }
                }
            }
            var results = try candidates.enumerated().map { i, p in
                try Screen.classify(package: p, batch: i / Screen.batchSize + 1, resolveFailure: failures[p.id],
                                    complete: cells[key(p.id, .strictCompleteV5)], minimal: cells[key(p.id, .minimalV5)])
            }

            var setIdentical = true
            if withVerify {
                let verifyCells = try RunStore(root: paths.runDirectory(sp.verifyRunId)).loadCells()
                results = try zip(candidates, results).map { p, r in
                    try Screen.applyVerify(r, package: p, complete: verifyCells[key(p.id, .strictCompleteV5)],
                                           minimal: verifyCells[key(p.id, .minimalV5)])
                }
                // A7 over the stable emitters' cells. Unstable ones differ by definition and are excluded above.
                let stable = Set(results.filter { $0.status == .emitter }.map(\.packageId))
                let report = RunComparison.compare(cells.filter { stable.contains($0.key.packageId) },
                                                   verifyCells.filter { stable.contains($0.key.packageId) })
                print("A7 over \(stable.count) stable emitters: \(report.cellsCompared) cells compared, \(report.identical) set-identical")
                for m in report.outcomeMismatches { print("OUTCOME DIFFERS \(m.key): \(m.left.rawValue) vs \(m.right.rawValue)") }
                for d in report.differing { print("MULTISET DIFFERS \(d.key): -\(d.difference.onlyInLeft.count) +\(d.difference.onlyInRight.count)") }
                for k in report.onlyInLeft + report.onlyInRight { print("MISSING IN ONE PASS \(k)") }
                setIdentical = report.isSetIdentical
            }

            let table = try Screen.denominator(drawn: candidates.count, results: results)
            print(table.rendered)
            let minimalFailed = results.filter { $0.status == .minimalFailed }
            if !minimalFailed.isEmpty { print("INVESTIGATE minimal_failed (expected ~0): " + minimalFailed.map(\.packageId).joined(separator: ", ")) }
            // A failed A7 check writes nothing: the pass-1 files on disk have no verify_screen_count, so selection refuses them.
            if !setIdentical {
                print("NOT SET-IDENTICAL across passes for stable emitters: investigate before selecting (spec §10a rule 6)")
                print("results.json and emitters.csv left at pass 1 (not written)")
                throw ExitCode.failure
            }
            try RunStore(root: sp.directory).write(results, to: sp.results)
            try Screen.emittersCSV(results: results, candidates: candidates, asOf: asOf)
                .write(to: sp.emitters, atomically: true, encoding: .utf8)
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read-only: how far the screen has got and what to do next (§10a). Safe at any time.")

        @OptionGroup var screen: ScreenOptions

        func run() async throws {
            let sp = screen.paths
            let fm = FileManager.default
            let launch = "cd \(fm.currentDirectoryPath) && " + (screen.root == "screens" ? "" : "SCREENS_ROOT=\(screen.root) ")
                + "nohup caffeinate -i scripts/screen-drive.sh \(sp.id) >/dev/null 2>&1 &"
            print("screen \(sp.id) at \(sp.directory.path)")
            guard fm.fileExists(atPath: sp.candidates.path) else {
                print("no candidates.yaml\nnext: census select screen --screen-id \(sp.id) --seed 20261004 --count 300; commit it; then launch:\n  \(launch)")
                return
            }
            let candidates = try sp.loadCandidates().packages
            let failures = try sp.resolveFailures()
            let resolved = candidates.filter(sp.hasResolved)
            print("candidates \(candidates.count); resolved \(resolved.count); resolve failures \(failures.count); "
                + "not yet resolved \(candidates.count - resolved.count - failures.count)")

            let tc = Screen.toolchain.name
            func progress(_ label: String, pool: [CorpusPackage], runId: (Int) -> String) throws {
                let total = Screen.batchCount(pool.count)
                for n in stride(from: 1, through: total, by: 1) {
                    let members = Screen.batch(n, of: pool).filter(sp.hasResolved)
                    let cells = try RunStore(root: sp.corpusPaths.runDirectory(runId(n))).loadCells()
                    let complete = members.compactMap { cells[RunStore.CellKey(toolchain: tc, mode: .strictCompleteV5, packageId: $0.id)] }
                    let needed = complete.filter(Screen.needsMinimal).count
                    let minimal = members.filter { cells[RunStore.CellKey(toolchain: tc, mode: .minimalV5, packageId: $0.id)] != nil }.count
                    let memberIds = Set(Screen.batch(n, of: pool).map(\.id))
                    let infra = cells.values.filter { $0.record.outcome == .infraError && memberIds.contains($0.record.packageId) }.count
                    let marker = fm.fileExists(atPath: sp.state.appendingPathComponent("\(label)-\(n).done").path) ? " [done]" : ""
                    print("  \(label) \(n)/\(total): complete \(complete.count)/\(members.count), minimal \(minimal)/\(needed)"
                        + (infra > 0 ? ", infra_error \(infra)" : "") + marker)
                }
            }
            print("pass 1:")
            try progress("batch", pool: candidates) { sp.runId(batch: $0) }
            if fm.fileExists(atPath: sp.results.path) {
                let results = try sp.loadResults()
                let byStatus = Dictionary(grouping: results, by: \.status).mapValues(\.count)
                print("results.json: " + ScreenStatus.allCases.map { "\($0.rawValue) \(byStatus[$0] ?? 0)" }.joined(separator: ", "))
                print("verify pass:")
                try progress("verify", pool: Screen.verifyPackages(results: results, candidates: candidates)) { _ in sp.verifyRunId }
            }

            let guests = ((try? await Shell.run("limactl", ["list", "--format", "{{.Name}}"]))?.stdoutString ?? "")
                .split(separator: "\n").map(String.init).filter { $0.hasPrefix("census-run-") }
            print("guest clones: " + (guests.isEmpty ? "none" : guests.joined(separator: ", ") + " (one is expected while a batch runs)"))

            let pidFile = sp.state.appendingPathComponent("driver.pid")
            var driverAlive = false
            if let pid = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let ps = try? await Shell.run("ps", ["-p", pid, "-o", "command="]) {
                driverAlive = ps.succeeded && ps.stdoutString.contains("screen-drive.sh")
            }
            print("driver: " + (driverAlive ? "running" : "not running"))
            if let log = try? String(contentsOf: sp.state.appendingPathComponent("drive.log"), encoding: .utf8),
               let last = log.split(separator: "\n").last {
                print("log: \(last)")
            }

            let stopped = try? String(contentsOf: sp.state.appendingPathComponent("STOPPED"), encoding: .utf8)
            let finished = fm.fileExists(atPath: sp.state.appendingPathComponent("collect-verify.done").path)
            if let stopped {
                print("STOPPED: \(stopped.trimmingCharacters(in: .whitespacesAndNewlines))")
                print("next: investigate (never paper over), fix, delete \(sp.state.path)/STOPPED, then relaunch:\n  \(launch)")
            } else if driverAlive {
                print("next: nothing; the driver is running. Re-run this command to check.")
            } else if finished {
                print("next: driver finished. Commit outputs; apply D5 if stable emitters < 45 (runbook step 8); then census select emit --from-screen \(sp.id)")
            } else {
                print("next: the driver is not running and has not finished. Relaunch (resumes; nothing is redone):\n  \(launch)")
            }
        }
    }
}
