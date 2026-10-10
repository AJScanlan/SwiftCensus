import ArgumentParser
import CensusCore
import CensusRunner
import Foundation
import Yams

struct Select: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Draw the sampled strata into corpus/packages.yaml (A3). S-anchor and S-byproduct are named by hand.",
        subcommands: [Control.self, Emit.self, ScreenDraw.self])
}

private let packageListRepo = "SwiftPackageIndex/PackageList"
/// D2 (ADR 0007): the PackageList commit `S-control` was drawn from. The screen draws from the same frame.
let pinnedPackageListSHA = "4dc1035a98457e87f4d2c5649a33cd43ee6b80e8"

private func save(_ manifest: CorpusManifest, to url: URL, replacing stratum: Stratum, with new: [CorpusPackage]) throws {
    var m = manifest
    m.packages.removeAll { $0.stratum == stratum }
    m.packages += new
    m.packages.sort { ($0.stratum.rawValue, $0.id) < ($1.stratum.rawValue, $1.id) }
    let header = "# corpus/packages.yaml — pinned corpus (P7). Edited by `census select`; bumping a SHA is a documented operation.\n"
    try CorpusYAML.encode(m, header: header).write(to: url, atomically: true, encoding: .utf8)
}

private func headSHA(_ url: String) async throws -> String? {
    let r = try await Shell.run("git", ["ls-remote", url, "HEAD"], timeout: 60)
    guard r.succeeded else { return nil }
    let sha = r.stdoutString.split(separator: "\t").first.map(String.init) ?? ""
    return CorpusManifest.isFullSHA(sha) ? sha : nil
}

/// The PackageList at `sha`, or at `main`'s current commit when nil. Pin the *list*, not just the draw:
/// a moving PackageList would make the seed meaningless.
private func packageList(at sha: String?) async throws -> (sha: String, repos: [String: String]) {
    let listSHA: String
    if let sha {
        listSHA = sha
    } else {
        listSHA = try await Shell.check("gh", ["api", "repos/\(packageListRepo)/commits/main", "--jq", ".sha"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let raw = try await Shell.check("curl", ["-fsSL", "https://raw.githubusercontent.com/\(packageListRepo)/\(listSHA)/packages.json"])
    let urls = try JSONDecoder().decode([String].self, from: raw.stdout)
    let repos = Draw.repos(fromPackageList: urls)
    print("PackageList@\(listSHA.prefix(10)): \(urls.count) urls, \(repos.count) GitHub repos")
    return (listSHA, repos)
}

/// The network half of eligibility; `Draw.checkMetadata` is the rule.
private func eligibility(id: String, url: String, now: Date, activeDays: Int) async throws -> Eligibility {
    let meta = try await Shell.run("gh", ["api", "repos/\(id)", "--jq", "[.archived, .disabled, .pushed_at, .default_branch] | @tsv"])
    switch Draw.checkMetadata(meta.succeeded ? meta.stdoutString : nil, now: now, activeDays: activeDays) {
    case .rejected(let reason):
        return .rejected(reason)
    case .active(let branch):
        guard let sha = try await headSHA(url) else { return .rejected("no HEAD sha") }
        print("  eligible \(id)")
        return .eligible(sha: sha, branch: branch)
    }
}

private func today() -> String { String(ISO8601DateFormatter().string(from: Date()).prefix(10)) }

extension Select {
    struct Control: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "S-control: a seeded uniform draw from the SPI PackageList, unconditioned on diagnostic count.")

        @Option(name: .long, help: "PRNG seed. Recorded in each entry's `selection`.") var seed: UInt64
        @Option(name: .long, help: "Entries to draw.") var count = 30
        @Option(name: .long, help: "Treat repos with no push in this many days as inactive.") var activeDays = 365

        func run() async throws {
            let paths = Paths()
            let manifest = try paths.loadManifest()
            let (listSHA, repos) = try await packageList(at: nil)
            let now = Date()
            let spec = DrawSpec(seed: seed, count: count, startPosition: 0, packageListSHA: listSHA, date: today(),
                                stratum: .control, platforms: [.linuxSPM])
            let result = try await Draw.draw(repos: repos, spec: spec, excluding: Set(manifest.packages.map(\.id))) { id, url in
                try await eligibility(id: id, url: url, now: now, activeDays: activeDays)
            }
            print("rejected before the draw completed: \(result.rejected)")
            try save(manifest, to: paths.corpus, replacing: .control, with: result.packages)
        }
    }

    /// ADR 0007 §5.1. Continues `S-control`'s seeded order over the same PackageList commit, skipping every id
    /// already in the corpus. Written in draw order, because batches are positional (an extension only appends).
    struct ScreenDraw: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "screen",
            abstract: "Draw screen candidates into <root>/<screen-id>/candidates.yaml (ADR 0007).")

        @Option(name: .long, help: "Screen id, ending in its date, e.g. screen-2026-10-10.") var screenId: String
        @Option(name: .long, help: "Directory holding screen directories.") var root = "screens"
        @Option(name: .long, help: "PRNG seed (pre-registered: 20261004).") var seed: UInt64
        @Option(name: .long, help: "Candidates to draw. Default 300; with --extend it is required and must be 150 (D5 pre-registers +150).") var count: Int?
        @Option(name: .long, help: "Treat repos with no push in this many days of the draw date as inactive.") var activeDays = 365
        @Option(name: .long, help: "PackageList commit (D2).") var packageListSha = pinnedPackageListSHA
        @Flag(name: .long, help: "D5: append --count more after the last drawn position instead of drawing afresh.") var extend = false

        func run() async throws {
            let count: Int
            do { count = try Screen.drawCount(requested: self.count, extend: extend) } catch { throw ValidationError("\(error)") }
            let corpus = try Paths().loadManifest()
            let sp = ScreenPaths(root: root, id: screenId)
            let fm = FileManager.default
            var candidates = CorpusManifest(packages: [])
            if fm.fileExists(atPath: sp.candidates.path) {
                guard extend else { throw ValidationError("\(sp.candidates.path) exists and is pinned; --extend appends to it (D5)") }
                candidates = try sp.loadCandidates()
                if let id = Draw.extensionMismatch(candidates.packages, seed: seed, packageListSHA: packageListSha) {
                    throw ValidationError("--extend must continue the same order: \(id) was drawn with a different seed or PackageList commit")
                }
            } else if extend {
                throw ValidationError("--extend needs an existing \(sp.candidates.path)")
            }
            let start = candidates.packages.compactMap { Draw.position(inSelection: $0.selection) }.max().map { $0 + 1 } ?? 0
            let (listSHA, repos) = try await packageList(at: packageListSha)
            let now = Date()
            let spec = DrawSpec(seed: seed, count: count, startPosition: start, packageListSHA: listSHA, date: today(),
                                stratum: .screen, platforms: [.macosSPM])
            let excluded = Set(corpus.packages.map(\.id)).union(candidates.packages.map(\.id))
            let result = try await Draw.draw(repos: repos, spec: spec, excluding: excluded) { id, url in
                try await eligibility(id: id, url: url, now: now, activeDays: activeDays)
            }
            print("drew \(result.packages.count) of \(count) from position \(start); rejected: \(result.rejected)")
            candidates.packages += result.packages
            try fm.createDirectory(at: sp.directory, withIntermediateDirectories: true)
            let header = "# Screen candidates (ADR 0007), in draw order. Written by `census select screen`; pinned like the corpus.\n"
            try CorpusYAML.encode(candidates, header: header).write(to: sp.candidates, atomically: true, encoding: .utf8)
        }
    }

    struct Emit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "S-emit: sample across the data-race count distribution, from a supplied SPI export (corpus/spi-counts.csv) or a collected screen (--from-screen).",
            discussion: "Columns: package_url,data_race_errors,swift_version,as_of. The data must come from SPI's own published figures.")

        @Option(name: .long, help: "SPI export.") var spiData = "corpus/spi-counts.csv"
        @Option(name: .long) var seed: UInt64
        @Option(name: .long) var count = 30
        @Option(name: .long, help: "Select from a collected screen (ADR 0007) instead of an SPI export.") var fromScreen: String?
        @Option(name: .long, help: "Directory holding screen directories.") var screensRoot = "screens"

        func run() async throws {
            let paths = Paths()
            let manifest = try paths.loadManifest()
            if let id = fromScreen {
                let sp = ScreenPaths(root: screensRoot, id: id)
                let selected = try Screen.selectEmit(results: try sp.loadResults(), candidates: try sp.loadCandidates().packages,
                                                     screenId: id, seed: seed, count: count)
                print("stable emitters \(selected.emitters); selected \(selected.entries.count) of \(count): "
                    + [Selection.Tertile.head, .middle, .tail].map { "\($0.rawValue) \(selected.perTertile[$0] ?? 0)" }.joined(separator: ", "))
                if selected.entries.count < count {
                    print("FEWER THAN \(count): taking what exists, not padding. Record this in ADR 0007's results.")
                }
                // Copy first: if it refuses, the manifest is untouched.
                try Screen.copyResolved(selected.entries, from: sp.resolved, to: paths.resolved)
                try save(manifest, to: paths.corpus, replacing: .emit, with: selected.entries)
                return
            }
            let rows = try Selection.parseSPICSV(String(contentsOfFile: spiData, encoding: .utf8))
            let sample = Selection.sampleAcrossDistribution(rows: rows, count: count, seed: seed)
            let date = today()
            var drawn: [CorpusPackage] = []
            for (row, tertile) in sample {
                guard let r = Selection.githubRepo(from: row.url) else { print("skip non-GitHub: \(row.url)"); continue }
                guard let sha = try await headSHA(r.url) else { print("skip (no HEAD): \(row.url)"); continue }
                drawn.append(CorpusPackage(
                    id: "\(r.owner)/\(r.repo)", url: r.url, sha: sha, stratum: .emit, platforms: [.linuxSPM],
                    selection: "seed=\(seed) \(tertile.rawValue)-tertile of \(rows.filter { $0.errors > 0 }.count) emitting; "
                        + "SPI \(row.swiftVersion) as of \(row.asOf); HEAD on \(date)",
                    spiErrorCountAtSelection: row.errors))
            }
            print("drew \(drawn.count) of \(sample.count) requested from \(rows.count) rows")
            try save(manifest, to: paths.corpus, replacing: .emit, with: drawn)
        }
    }
}
