import Foundation
import Testing

@testable import CensusRunner

@Suite struct SelectionTests {
    @Test(arguments: [
        ("https://github.com/apple/swift-nio.git", "apple/swift-nio"),
        ("https://github.com/apple/swift-nio", "apple/swift-nio"),
        ("https://github.com/apple/swift-nio/", "apple/swift-nio"),
        ("https://GitHub.com/vapor/vapor.git", "vapor/vapor"),
    ])
    func canonicalisesGitHubURLs(raw: String, id: String) {
        let r = Selection.githubRepo(from: raw)
        #expect(r.map { "\($0.owner)/\($0.repo)" } == id)
        #expect(r?.url.hasSuffix(".git") == false)
    }

    @Test(arguments: ["https://gitlab.com/a/b.git", "https://github.com/onlyowner", "https://github.com/a/b/c", "not a url"])
    func rejectsNonGitHubOrMalformed(raw: String) {
        #expect(Selection.githubRepo(from: raw) == nil)
    }

    /// Golden values pin SplitMix64 and the shuffle: if these change, every seeded corpus draw
    /// changes, and that must be a deliberate documented operation, not a stdlib upgrade.
    @Test func splitMix64MatchesReferenceVector() {
        var rng = SplitMix64(seed: 0)
        #expect(rng.next() == 0xE220_A839_7B1D_CDAF)
        #expect(rng.next() == 0x6E78_9E6A_A1B9_65F4)
    }

    @Test func shuffleIsDeterministicAndOrderIndependent() {
        let items = (0..<50).map { "pkg\($0)" }
        let a = Selection.seededShuffle(items, seed: 42)
        #expect(a == Selection.seededShuffle(items.reversed(), seed: 42))
        #expect(a != Selection.seededShuffle(items, seed: 43))
        #expect(a.sorted() == items.sorted())
    }

    @Test func parsesSPICSVAndRejectsMalformedRows() throws {
        let ok = "# comment\npackage_url,data_race_errors,swift_version,as_of\nhttps://github.com/a/b,12,6.1,2025-05-07\n"
        #expect(try Selection.parseSPICSV(ok) == [SPIRow(url: "https://github.com/a/b", errors: 12, swiftVersion: "6.1", asOf: "2025-05-07")])
        #expect(throws: SelectionError.self) { try Selection.parseSPICSV("a,b,c,d\n") }
        #expect(throws: SelectionError.self) {
            try Selection.parseSPICSV("package_url,data_race_errors,swift_version,as_of\nx,notanumber,6.1,d\n")
        }
    }

    @Test func distributionSampleDrawsEqualSharesFromHeadMiddleAndTail() {
        // 90 emitting packages: counts 1...90, plus 10 clean ones that must never be drawn.
        let rows = (1...90).map { SPIRow(url: "https://github.com/o/r\($0)", errors: $0, swiftVersion: "6.1", asOf: "x") }
            + (1...10).map { SPIRow(url: "https://github.com/o/clean\($0)", errors: 0, swiftVersion: "6.1", asOf: "x") }
        let sample = Selection.sampleAcrossDistribution(rows: rows, count: 30, seed: 7)
        #expect(sample.count == 30)
        #expect(sample.allSatisfy { $0.row.errors > 0 })
        let byTertile = Dictionary(grouping: sample, by: \.tertile).mapValues(\.count)
        #expect(byTertile[.head] == 10 && byTertile[.middle] == 10 && byTertile[.tail] == 10)
        // Head is the highest counts, tail the lowest.
        #expect(sample.filter { $0.tertile == .head }.allSatisfy { $0.row.errors > 60 })
        #expect(sample.filter { $0.tertile == .tail }.allSatisfy { $0.row.errors <= 30 })
        #expect(sample.map(\.row) == Selection.sampleAcrossDistribution(rows: rows.reversed(), count: 30, seed: 7).map(\.row))
    }

    @Test func distributionSampleHandlesTinyAndEmptyInputs() {
        #expect(Selection.sampleAcrossDistribution(rows: [], count: 30, seed: 1).isEmpty)
        let one = [SPIRow(url: "https://github.com/o/r", errors: 3, swiftVersion: "6.1", asOf: "x")]
        #expect(Selection.sampleAcrossDistribution(rows: one, count: 30, seed: 1).count == 1)
    }
}
