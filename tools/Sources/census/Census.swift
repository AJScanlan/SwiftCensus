import ArgumentParser
import CensusCore
import CensusRunner
import Foundation
import SuppressionScan
import Yams

@main
struct Census: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "swift-diagnostic-census instrument.",
        subcommands: [Validate.self, Select.self, Resolve.self, Run.self, Scan.self, Compare.self])
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
        abstract: "Vendor a Package.resolved per corpus entry (F1). A documented operation, never a drive-by.")

    @Option(name: .long, help: "Toolchain used to resolve.") var toolchain = "6.4"
    @Option(name: .long, parsing: .upToNextOption, help: "Only these package ids.") var package: [String] = []

    func run() async throws {
        let paths = Paths()
        let manifest = try paths.loadManifest()
        guard let tc = Toolchain.named(toolchain) else { throw ValidationError("unknown toolchain \(toolchain)") }
        try FileManager.default.createDirectory(at: paths.scratch, withIntermediateDirectories: true)
        let resolver = Resolver(sources: paths.sources, resolvedDirectory: paths.resolved, scratch: paths.scratch, toolchain: tc)

        let provenanceURL = paths.resolved.appendingPathComponent("provenance.json")
        var provenance = (try? JSONDecoder().decode([String: ResolvedProvenance].self, from: Data(contentsOf: provenanceURL))) ?? [:]
        var failures = 0
        for p in manifest.packages where p.skipReason == nil && (package.isEmpty || package.contains(p.id)) {
            do {
                let result = try await resolver.resolve(p)
                provenance[p.id] = result
                print("resolved \(p.id): \(result.source), \(result.pinCount) pins")
            } catch {
                failures += 1
                print("FAILED \(p.id): \(error)")
            }
            try RunStore(root: paths.resolved).write(provenance, to: provenanceURL)
        }
        if failures > 0 { throw ExitCode.failure }
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the matrix (Linux, containerised) and commit raw output under runs/<run-id>/.")

    @Option(name: .long, help: "Run identifier; the directory name under runs/.") var runId: String
    @Option(name: .long, parsing: .upToNextOption, help: "Toolchains (default: all of 6.1 6.2 6.3 6.4 nightly).") var toolchain: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "Only these package ids.") var package: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "Only these strata, e.g. S-anchor.") var stratum: [String] = []
    @Option(name: .long, help: "Parallel cells.") var jobs = 1
    @Option(name: .long, help: "CPUs per container.") var cpus = 4
    @Option(name: .long, help: "Memory GB per container.") var memoryGb = 6
    @Option(name: .long, help: "Per-cell timeout, minutes.") var timeoutMinutes = 45
    @Flag(name: .long, help: "Re-run cells that already have results.") var force = false

    func run() async throws {
        let paths = Paths()
        let manifest = try paths.loadManifest()
        let issues = manifest.validate()
        guard issues.isEmpty else {
            issues.forEach { print("invalid: \($0)") }
            throw ExitCode.failure
        }
        let toolchains = try (toolchain.isEmpty ? Toolchain.matrix.map(\.name) : toolchain).map { name -> Toolchain in
            guard let t = Toolchain.named(name) else { throw ValidationError("unknown toolchain \(name)") }
            return t
        }
        let strata = try Set(stratum.map { s -> Stratum in
            guard let v = Stratum(rawValue: s) else { throw ValidationError("unknown stratum \(s)") }
            return v
        })
        let selection = MatrixSelection(
            toolchains: toolchains, packageIds: package.isEmpty ? nil : Set(package),
            strata: strata.isEmpty ? nil : strata)

        let runDir = paths.runDirectory(runId)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.scratch, withIntermediateDirectories: true)
        let store = RunStore(root: runDir)
        try await writeRunManifest(paths: paths, store: store, toolchains: toolchains)

        let cells = MatrixRun.plan(manifest: manifest, selection: selection)
        // Fetch all sources up front, sequentially: two cells of one package must not race a clone.
        for p in Set(cells.map(\.package.id)).sorted() {
            if let pkg = manifest.packages.first(where: { $0.id == p }) {
                print("source \(p)@\(pkg.sha.prefix(8))")
                try await paths.sources.ensure(pkg)
            }
        }
        let runner = CellRunner(
            sources: paths.sources, resolvedDirectory: paths.resolved, store: store, scratch: paths.scratch,
            limits: CellLimits(cpus: cpus, memoryGB: memoryGb, timeout: TimeInterval(timeoutMinutes * 60)), runId: runId)
        await MatrixRun.execute(cells: cells, runner: runner, jobs: jobs, force: force) { print($0); fflush(stdout) }
    }

    private func writeRunManifest(paths: Paths, store: RunStore, toolchains: [Toolchain]) async throws {
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
            hostPlatform: "\(ProcessInfo.processInfo.operatingSystemVersionString) (container runtime)",
            dockerServerVersion: docker, toolchains: Dictionary(uniqueKeysWithValues: toolchains.map { ($0.name, $0.image) }),
            modes: Mode.allCases, platform: .linuxSPM)
        try store.write(manifest, to: url)
    }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "SuppressionScan over every corpus checkout (A10). Compiles nothing.")

    @Option(name: .long, help: "Output file.") var output = "corpus/suppression.json"

    func run() async throws {
        let paths = Paths()
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
