import ArgumentParser
import CensusCore
import CensusRunner
import Foundation
import Yams

struct Select: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Draw the sampled strata into corpus/packages.yaml (A3). S-anchor and S-byproduct are named by hand.",
        subcommands: [Control.self, Emit.self])
}

private let packageListRepo = "SwiftPackageIndex/PackageList"

private func save(_ manifest: CorpusManifest, to url: URL, replacing stratum: Stratum, with new: [CorpusPackage]) throws {
    var m = manifest
    m.packages.removeAll { $0.stratum == stratum }
    m.packages += new
    m.packages.sort { ($0.stratum.rawValue, $0.id) < ($1.stratum.rawValue, $1.id) }
    var encoder = YAMLEncoder()
    encoder.options.sortKeys = true
    encoder.options.width = 120
    let header = "# corpus/packages.yaml — pinned corpus (P7). Edited by `census select`; bumping a SHA is a documented operation.\n"
    try (header + encoder.encode(m)).write(to: url, atomically: true, encoding: .utf8)
}

private func headSHA(_ url: String) async throws -> String? {
    let r = try await Shell.run("git", ["ls-remote", url, "HEAD"], timeout: 60)
    guard r.succeeded else { return nil }
    let sha = r.stdoutString.split(separator: "\t").first.map(String.init) ?? ""
    return CorpusManifest.isFullSHA(sha) ? sha : nil
}

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
            let existing = Set(manifest.packages.map(\.id))

            // Pin the *list*, not just the draw: a moving PackageList would make the seed meaningless.
            let listSHA = try await Shell.check("gh", ["api", "repos/\(packageListRepo)/commits/main", "--jq", ".sha"])
                .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = try await Shell.check("curl", ["-fsSL", "https://raw.githubusercontent.com/\(packageListRepo)/\(listSHA)/packages.json"])
            let urls = try JSONDecoder().decode([String].self, from: raw.stdout)
            var byId: [String: String] = [:]
            for u in urls { if let r = Selection.githubRepo(from: u) { byId["\(r.owner)/\(r.repo)"] = r.url } }
            print("PackageList@\(listSHA.prefix(10)): \(urls.count) urls, \(byId.count) GitHub repos")

            let cutoff = Date().addingTimeInterval(-Double(activeDays) * 86400)
            let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
            var drawn: [CorpusPackage] = []
            var rejected: [String: Int] = [:]
            for (position, id) in Selection.seededShuffle(Array(byId.keys), seed: seed).enumerated() {
                if drawn.count >= count { break }
                if existing.contains(id) { rejected["already in corpus", default: 0] += 1; continue }
                guard let url = byId[id] else { continue }
                let meta = try await Shell.run("gh", ["api", "repos/\(id)", "--jq",
                    "[.archived, .disabled, .pushed_at, .default_branch] | @tsv"])
                let f = meta.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").map(String.init)
                guard meta.succeeded, f.count == 4 else { rejected["unavailable (renamed/removed)", default: 0] += 1; continue }
                if f[0] == "true" || f[1] == "true" { rejected["archived or disabled", default: 0] += 1; continue }
                guard let pushed = ISO8601DateFormatter().date(from: f[2]), pushed >= cutoff else {
                    rejected["inactive > \(activeDays)d", default: 0] += 1; continue
                }
                guard let sha = try await headSHA(url) else { rejected["no HEAD sha", default: 0] += 1; continue }
                drawn.append(CorpusPackage(
                    id: id, url: url, sha: sha, stratum: .control, platforms: [.linuxSPM],
                    selection: "seed=\(seed) draw-position=\(position) PackageList@\(listSHA) HEAD of \(f[3]) on \(today)"))
                print("  [\(drawn.count)/\(count)] \(id)")
            }
            print("rejected before the draw completed: \(rejected)")
            try save(manifest, to: paths.corpus, replacing: .control, with: drawn)
        }
    }

    struct Emit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "S-emit: sample across SPI's data-race count distribution from a supplied export (corpus/spi-counts.csv).",
            discussion: "Columns: package_url,data_race_errors,swift_version,as_of. The data must come from SPI's own published figures.")

        @Option(name: .long, help: "SPI export.") var spiData = "corpus/spi-counts.csv"
        @Option(name: .long) var seed: UInt64
        @Option(name: .long) var count = 30

        func run() async throws {
            let paths = Paths()
            let manifest = try paths.loadManifest()
            let rows = try Selection.parseSPICSV(String(contentsOfFile: spiData, encoding: .utf8))
            let sample = Selection.sampleAcrossDistribution(rows: rows, count: count, seed: seed)
            let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
            var drawn: [CorpusPackage] = []
            for (row, tertile) in sample {
                guard let r = Selection.githubRepo(from: row.url) else { print("skip non-GitHub: \(row.url)"); continue }
                guard let sha = try await headSHA(r.url) else { print("skip (no HEAD): \(row.url)"); continue }
                drawn.append(CorpusPackage(
                    id: "\(r.owner)/\(r.repo)", url: r.url, sha: sha, stratum: .emit, platforms: [.linuxSPM],
                    selection: "seed=\(seed) \(tertile.rawValue)-tertile of \(rows.filter { $0.errors > 0 }.count) emitting; "
                        + "SPI \(row.swiftVersion) as of \(row.asOf); HEAD on \(today)",
                    spiErrorCountAtSelection: row.errors))
            }
            print("drew \(drawn.count) of \(sample.count) requested from \(rows.count) rows")
            try save(manifest, to: paths.corpus, replacing: .emit, with: drawn)
        }
    }
}
