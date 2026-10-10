import ArgumentParser
import CensusCore
import CensusRunner
import DiagParse
import Foundation
import SuppressionScan
import Yams

@main
struct Census: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "swift-diagnostic-census instrument.",
        subcommands: [Validate.self, Select.self, Resolve.self, Run.self, Scan.self, Compare.self, Parse.self, Reclassify.self, ScreenCommand.self])
}

/// Everything resolves relative to the repository root (the current directory).
struct Paths {
    var corpus = URL(fileURLWithPath: "corpus/packages.yaml")
    var resolved = URL(fileURLWithPath: "corpus/resolved")
    var work = URL(fileURLWithPath: "work")
    var sources: SourceCache { SourceCache(root: work.appendingPathComponent("src")) }
    var scratch: URL { work.appendingPathComponent("scratch") }
    func runDirectory(_ id: String) -> URL { URL(fileURLWithPath: "runs/\(id)") }

    func loadManifest() throws -> CorpusManifest {
        try YAMLDecoder().decode(CorpusManifest.self, from: String(contentsOf: corpus, encoding: .utf8))
    }
}

/// `--manifest`/`--resolved` let the screen (ADR 0007) keep its candidates outside `corpus/`. Defaults are the corpus.
struct CorpusOptions: ParsableArguments {
    @Option(name: .long, help: "Corpus manifest.") var manifest = "corpus/packages.yaml"
    @Option(name: .long, help: "Directory of vendored Package.resolved files.") var resolved = "corpus/resolved"
    var paths: Paths { Paths(corpus: URL(fileURLWithPath: manifest), resolved: URL(fileURLWithPath: resolved)) }
}

/// Written once per run directory, before its first cell.
func writeRunManifest(runId: String, paths: Paths, store: RunStore, toolchains: [Toolchain], platform: Platform,
                      hostPlatform: String) async throws {
    let url = store.root.appendingPathComponent("run.json")
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    let commit = try? await Shell.run("git", ["rev-parse", "HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    let dirty = try? await Shell.run("git", ["status", "--porcelain", "--", "tools", "corpus"]).stdoutString
    let docker = try? await Shell.run("docker", ["version", "--format", "{{.Server.Version}}"]).stdoutString
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let manifest = RunManifest(
        runId: runId, startedAt: ISO8601DateFormatter().string(from: Date()), toolsGitCommit: commit,
        toolsGitDirty: dirty.map { !$0.isEmpty },
        corpusManifestSHA256: try MatrixRun.sha256Hex(of: paths.corpus),
        hostPlatform: hostPlatform,
        dockerServerVersion: platform == .linuxSPM ? docker : nil,
        toolchains: Dictionary(uniqueKeysWithValues: toolchains.map { ($0.name, $0.image) }),
        modes: Mode.allCases, platform: platform)
    try store.write(manifest, to: url)
}

/// One fresh clone of the golden guest for the duration of `body`, always destroyed afterwards (ADR 0006:
/// isolation is per run). `GuestVM.create()` deletes any stale clone of the same name first. A failure to bring the
/// guest up is thrown as `GuestBootError`; anything thrown by `body` is rethrown unchanged.
func withMacGuest(runId: String, paths: Paths, store: RunStore, timeoutMinutes: Int,
                  _ body: (MacCellRunner) async throws -> Void) async throws {
    let vm = GuestVM(runId: runId)
    print("cloning \(GuestVM.goldenName) -> \(vm.instance)")
    do {
        try await vm.create()
    } catch {
        await vm.destroy()  // a half-booted clone must not keep holding the guest's RAM
        throw GuestBootError(error)
    }
    let guestInfo = await vm.describe()
    print("guest:\n\(guestInfo)")
    do {
        try await writeRunManifest(
            runId: runId, paths: paths, store: store, toolchains: [Toolchain.macOSXcode], platform: .macosSPM,
            hostPlatform: "macOS guest (Lima/vz): " + guestInfo.replacingOccurrences(of: "\n", with: "; "))
        let runner = MacCellRunner(
            vm: vm, sources: paths.sources, resolvedDirectory: paths.resolved, store: store,
            scratch: paths.scratch, timeout: TimeInterval(timeoutMinutes * 60), imageID: GuestVM.restoreImageDigest())
        try await body(runner)
    } catch {
        await vm.destroy()
        throw error
    }
    await vm.destroy()
}

/// Missing means empty; present but undecodable is an error, never a silent reset (a reset would re-resolve pinned graphs).
func loadJSON<T: Decodable>(_ type: T.Type, from url: URL, default empty: T) throws -> T {
    guard FileManager.default.fileExists(atPath: url.path) else { return empty }
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

struct Validate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Validate corpus/packages.yaml (P7: pinned SHAs).")

    func run() async throws {
        let manifest = try Paths().loadManifest()
        let issues = manifest.validate()
        for issue in issues { print("invalid: \(issue)") }
        let byStratum = Dictionary(grouping: manifest.packages, by: \.stratum).mapValues(\.count)
        print("\(manifest.packages.count) packages; " + Stratum.allCases.map { "\($0.rawValue)=\(byStratum[$0] ?? 0)" }.joined(separator: " "))
        if !issues.isEmpty { throw ExitCode.failure }
    }
}

struct Resolve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Vendor a Package.resolved per corpus entry (F1). A documented operation, never a drive-by.",
        discussion: "Skips packages already vendored (G3); --force re-resolves them.")

    @OptionGroup var corpus: CorpusOptions
    @Option(name: .long, help: "Toolchain used to resolve.") var toolchain = "6.4"
    @Option(name: .long, parsing: .upToNextOption, help: "Only these package ids.") var package: [String] = []
    @Flag(name: .long, help: "Re-resolve packages that already have a vendored file.") var force = false
    @Flag(name: .long, help: "Record genuine dependency-resolution failures in failures.json and exit 0: the screen's unresolvable candidates are data. Infrastructure errors (docker, timeout, source fetch) are never recorded and still stop the command with a non-zero exit.") var allowFailures = false
    @Option(name: .long, help: "Record this package id as unresolvable by operator decision, without resolving anything (for a source fetch that fails identically every time). Requires --reason.") var recordUnresolvable: String?
    @Option(name: .long, help: "Why --record-unresolvable applies; stored as \"operator: <reason>\".") var reason: String?

    func validate() throws {
        if (recordUnresolvable == nil) != (reason == nil) {
            throw ValidationError("--record-unresolvable and --reason must be given together")
        }
    }

    func run() async throws {
        let paths = corpus.paths
        let manifest = try paths.loadManifest()
        let provenanceURL = paths.resolved.appendingPathComponent("provenance.json")
        let failuresURL = paths.resolved.appendingPathComponent("failures.json")
        if let id = recordUnresolvable, let reason {
            guard let p = manifest.packages.first(where: { $0.id == id }) else {
                throw ValidationError("\(id) is not in the manifest \(corpus.manifest)")
            }
            let provenance = try loadJSON([String: ResolvedProvenance].self, from: provenanceURL, default: [:])
            if provenance[id] != nil && FileManager.default.fileExists(
                atPath: paths.resolved.appendingPathComponent("\(p.slug).resolved").path) {
                throw ValidationError("\(id) already has a vendored Package.resolved; refusing to mark it unresolvable")
            }
            var failed = try loadJSON([String: String].self, from: failuresURL, default: [:])
            failed[id] = Resolver.operatorFailurePrefix + reason
            try FileManager.default.createDirectory(at: paths.resolved, withIntermediateDirectories: true)
            try RunStore(root: paths.resolved).write(failed, to: failuresURL)
            print("recorded \(id) unresolvable: \(failed[id]!)")
            return
        }
        guard let tc = Toolchain.named(toolchain) else { throw ValidationError("unknown toolchain \(toolchain)") }
        try FileManager.default.createDirectory(at: paths.scratch, withIntermediateDirectories: true)
        let resolver = Resolver(sources: paths.sources, resolvedDirectory: paths.resolved, scratch: paths.scratch, toolchain: tc)
        let store = RunStore(root: paths.resolved)

        var provenance = try loadJSON([String: ResolvedProvenance].self, from: provenanceURL, default: [:])
        var failed = try loadJSON([String: String].self, from: failuresURL, default: [:])
        let selected = manifest.packages.filter { $0.skipReason == nil && (package.isEmpty || package.contains($0.id)) }
        let pending = Resolver.pending(selected, resolvedDirectory: paths.resolved, provenance: provenance, failures: failed, force: force)
        print("\(pending.count) to resolve (\(selected.count - pending.count) already vendored)")
        var failures = 0
        for p in pending {
            do {
                let result = try await resolver.resolve(p)
                provenance[p.id] = result
                failed[p.id] = nil
                print("resolved \(p.id): \(result.source), \(result.pinCount) pins")
            } catch {
                guard Resolver.isPackageFailure(error) else {
                    // Not a property of the package: record nothing, and stop at once so a dead Docker does not
                    // churn through every remaining candidate. Rerunning resumes (G3).
                    print("INFRA \(p.id): \(error)")
                    throw ExitCode.failure
                }
                failures += 1
                failed[p.id] = "\(error)"
                print("FAILED \(p.id): \(error)")
            }
            try store.write(provenance, to: provenanceURL)
            if failed.isEmpty { try? FileManager.default.removeItem(at: failuresURL) } else { try store.write(failed, to: failuresURL) }
        }
        if failures > 0 && !allowFailures { throw ExitCode.failure }
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the matrix (Linux, containerised) and commit raw output under runs/<run-id>/.")

    @OptionGroup var corpus: CorpusOptions
    @Option(name: .long, help: "Run identifier; the directory name under runs/.") var runId: String
    @Option(name: .long, help: "linux (Docker, five toolchains) or macos (Lima guest, Xcode 27). Platforms never share a run id (F6).") var platform = "linux"
    @Option(name: .long, parsing: .upToNextOption, help: "Toolchains (default: all of 6.1 6.2 6.3 6.4 nightly).") var toolchain: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "Only these package ids.") var package: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "Only these strata, e.g. S-anchor.") var stratum: [String] = []
    @Option(name: .long, help: "Parallel cells.") var jobs = 1
    @Option(name: .long, help: "CPUs per container.") var cpus = 4
    @Option(name: .long, help: "Memory GB per container.") var memoryGb = 6
    @Option(name: .long, help: "Per-cell timeout, minutes.") var timeoutMinutes = 45
    @Flag(name: .long, help: "Re-run cells that already have results.") var force = false

    func run() async throws {
        let paths = corpus.paths
        let manifest = try paths.loadManifest()
        let issues = manifest.validate()
        guard issues.isEmpty else {
            issues.forEach { print("invalid: \($0)") }
            throw ExitCode.failure
        }
        guard let target = ["linux": Platform.linuxSPM, "macos": .macosSPM][platform] else {
            throw ValidationError("--platform must be linux or macos")
        }
        let toolchains: [Toolchain]
        if target == .macosSPM {
            guard toolchain.isEmpty else { throw ValidationError("macOS has one toolchain column; omit --toolchain") }
            toolchains = [Toolchain.macOSXcode]
        } else {
            toolchains = try (toolchain.isEmpty ? Toolchain.matrix.map(\.name) : toolchain).map { name -> Toolchain in
                guard let t = Toolchain.named(name) else { throw ValidationError("unknown toolchain \(name)") }
                return t
            }
        }
        let strata = try Set(stratum.map { s -> Stratum in
            guard let v = Stratum(rawValue: s) else { throw ValidationError("unknown stratum \(s)") }
            return v
        })
        let selection = MatrixSelection(
            platform: target, toolchains: toolchains, packageIds: package.isEmpty ? nil : Set(package),
            strata: strata.isEmpty ? nil : strata)

        let runDir = paths.runDirectory(runId)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.scratch, withIntermediateDirectories: true)
        let store = RunStore(root: runDir)

        let cells = MatrixRun.plan(manifest: manifest, selection: selection)
        // Fetch all sources up front, sequentially: two cells of one package must not race a clone.
        for p in Set(cells.map(\.package.id)).sorted() {
            if let pkg = manifest.packages.first(where: { $0.id == p }) {
                print("source \(p)@\(pkg.sha.prefix(8))")
                try await paths.sources.ensure(pkg)
            }
        }

        if target == .macosSPM {
            try await withMacGuest(runId: runId, paths: paths, store: store, timeoutMinutes: timeoutMinutes) { runner in
                await MatrixRun.execute(cells: cells, runner: runner, jobs: 1, force: force,
                                        imageID: { _ in GuestVM.restoreImageDigest() }) { print($0); fflush(stdout) }
            }
            return
        }

        try await writeRunManifest(runId: runId, paths: paths, store: store, toolchains: toolchains, platform: target,
                                   hostPlatform: "\(ProcessInfo.processInfo.operatingSystemVersionString) (container runtime)")
        let runner = CellRunner(
            sources: paths.sources, resolvedDirectory: paths.resolved, store: store, scratch: paths.scratch,
            limits: CellLimits(cpus: cpus, memoryGB: memoryGb, timeout: TimeInterval(timeoutMinutes * 60)), runId: runId)
        await MatrixRun.execute(cells: cells, runner: runner, jobs: jobs, force: force) { print($0); fflush(stdout) }
    }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "SuppressionScan over every corpus checkout (A10). Compiles nothing.")

    @OptionGroup var corpus: CorpusOptions
    @Option(name: .long, help: "Output file (default corpus/suppression.json, only with the default --manifest).") var output: String?

    func run() async throws {
        guard let output = output ?? (corpus.manifest == "corpus/packages.yaml" ? "corpus/suppression.json" : nil) else {
            throw ValidationError("--output is required with a non-default --manifest")
        }
        let paths = corpus.paths
        let manifest = try paths.loadManifest()
        var results: [String: PackageScan] = [:]
        for p in manifest.packages {
            let dir = try await paths.sources.ensure(p)
            results[p.id] = try SuppressionScan.scanPackage(root: dir)
            let r = results[p.id]!
            print("\(p.id): \(r.nonCommentLines) lines, clean-parse \(String(format: "%.0f", r.cleanParseFraction * 100))%, \(r.counts)")
        }
        try RunStore(root: URL(fileURLWithPath: ".")).write(results, to: URL(fileURLWithPath: output))
    }
}

struct Compare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A7: are two runs' normalised diagnostic multisets set-identical?")

    @Argument(help: "First run directory.") var left: String
    @Argument(help: "Second run directory.") var right: String

    func run() async throws {
        let l = try RunStore(root: URL(fileURLWithPath: left)).loadCells()
        let r = try RunStore(root: URL(fileURLWithPath: right)).loadCells()
        let report = RunComparison.compare(l, r)
        print("cells compared: \(report.cellsCompared); set-identical: \(report.identical); "
            + "no-diagnostic outcomes (equal): \(report.noDiagnosticCells)")
        for k in report.onlyInLeft { print("only in \(left): \(k)") }
        for k in report.onlyInRight { print("only in \(right): \(k)") }
        for m in report.outcomeMismatches { print("OUTCOME DIFFERS \(m.key): \(m.left.rawValue) vs \(m.right.rawValue)") }
        for d in report.differing {
            print("MULTISET DIFFERS \(d.key): -\(d.difference.onlyInLeft.count) +\(d.difference.onlyInRight.count)")
            for k in d.difference.onlyInLeft.prefix(5) { print("  only left : \(k.id) \(k.path):\(k.line):\(k.col) \(k.severity.rawValue)") }
            for k in d.difference.onlyInRight.prefix(5) { print("  only right: \(k.id) \(k.path):\(k.line):\(k.col) \(k.severity.rawValue)") }
        }
        print(report.isSetIdentical ? "SET-IDENTICAL" : "NOT SET-IDENTICAL")
        if !report.isSetIdentical { throw ExitCode.failure }
    }
}

struct Parse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Parse a tarball of .dia files into diagnostics.json and print the tally. Used by non-Docker runners.")

    @Argument(help: "dia.tar.gz produced by the build.") var tarball: String
    @Option(name: .long, help: "Package root as the compiler saw it, e.g. /Users/aj.guest/census/yams.") var root: String
    @Option(name: .long, help: "Where to write diagnostics.json.") var output: String?

    func run() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("census-parse-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await Shell.check("tar", ["-xzf", tarball, "-C", scratch.path])
        let parsed = DiagParse.parse(diaFiles: DiagParse.enumerateDia(under: scratch), packageRoot: root)
        let tally = DiagnosticTally(records: parsed.records)
        print("dia files \(parsed.diaFilesFound) (empty \(parsed.emptyDiaFiles), unreadable \(parsed.unreadable.count)); \(tally)")
        if let output { try RunStore(root: URL(fileURLWithPath: ".")).write(parsed.records, to: URL(fileURLWithPath: output)) }
    }
}

struct Reclassify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-derive each committed cell's outcome from its raw build.log.gz (no rebuild).",
        discussion: "Dry run unless --write. The raw bytes are committed so a classifier fix never needs a re-run.")

    @Argument(help: "Run directory, e.g. runs/2026-10-10-macos.") var run: String
    @Flag(name: .long, help: "Rewrite cell.json where the outcome changed.") var write = false

    func run() async throws {
        let store = RunStore(root: URL(fileURLWithPath: run))
        var changed = 0, total = 0
        for (key, cell) in try store.loadCells().sorted(by: { $0.key < $1.key }) {
            total += 1
            let gz = cell.directory.appendingPathComponent("build.log.gz")
            let log = try await Shell.check("gzip", ["-dc", gz.path]).stdoutString
            let new = OutcomeClassifier.reclassify(cell.record, log: log)
            guard new != cell.record.outcome else { continue }
            changed += 1
            print("\(key): \(cell.record.outcome.rawValue) -> \(new.rawValue)")
            if write {
                var r = cell.record
                r.outcome = new
                try store.write(r, to: cell.directory.appendingPathComponent("cell.json"))
            }
        }
        print("\(changed) of \(total) cells \(write ? "rewritten" : "would change")")
    }
}
