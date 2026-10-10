import CensusCore
import Foundation
import Testing

@testable import CensusRunner

@Suite struct DrawTests {
    let list = (0..<40).map { "https://github.com/o/r\($0).git" } + ["https://gitlab.com/x/y"]
    let sha = String(repeating: "b", count: 40)
    let golden = ["o/r18", "o/r12", "o/r8", "o/r28", "o/r34", "o/r33", "o/r23", "o/r3", "o/r31", "o/r20"]

    func spec(count: Int = 5, start: Int = 0) -> DrawSpec {
        DrawSpec(seed: 20261004, count: count, startPosition: start, packageListSHA: "4dc1035a98457e87f4d2c5649a33cd43ee6b80e8",
                 date: "2026-10-10", stratum: .screen, platforms: [.macosSPM])
    }

    func eligible(_ id: String, _ url: String) async -> Eligibility { .eligible(sha: String(repeating: "b", count: 40), branch: "main") }

    @Test func drawFollowsTheGoldenSeededOrder() async {
        let repos = Draw.repos(fromPackageList: list)
        #expect(repos.count == 40)  // the non-GitHub URL is dropped
        let r = await Draw.draw(repos: repos, spec: spec(), excluding: [], check: eligible)
        #expect(r.packages.map(\.id) == Array(golden.prefix(5)))
        #expect(r.packages.allSatisfy { $0.stratum == .screen && $0.platforms == [.macosSPM] && $0.sha == sha })
        #expect(r.packages[0].url == "https://github.com/o/r18")
        #expect(r.packages[0].selection
            == "seed=20261004 draw-position=0 PackageList@4dc1035a98457e87f4d2c5649a33cd43ee6b80e8 HEAD of main on 2026-10-10")
    }

    /// D3: corpus ids are consumed positions. They are skipped and the next ones taken.
    @Test func excludedIdsAreSkippedAndTheNextOnesTaken() async {
        let r = await Draw.draw(repos: Draw.repos(fromPackageList: list), spec: spec(), excluding: ["o/r18", "o/r8"], check: eligible)
        #expect(r.packages.map(\.id) == ["o/r12", "o/r28", "o/r34", "o/r33", "o/r23"])
        #expect(r.rejected == ["already in corpus or candidates": 2])
        #expect(Draw.position(inSelection: r.packages[0].selection) == 1)
    }

    @Test func ineligibleReposAreCountedByReasonAndReplacedByTheNext() async {
        let r = await Draw.draw(repos: Draw.repos(fromPackageList: list), spec: spec(count: 3), excluding: []) { id, _ in
            id == "o/r12" ? .rejected("archived or disabled") : .eligible(sha: String(repeating: "b", count: 40), branch: "main")
        }
        #expect(r.packages.map(\.id) == ["o/r18", "o/r8", "o/r28"])
        #expect(r.rejected == ["archived or disabled": 1])
    }

    /// D5: an extension continues after the last drawn position and never revisits earlier ones.
    @Test func extensionContinuesTheSameOrder() async {
        let repos = Draw.repos(fromPackageList: list)
        let first = await Draw.draw(repos: repos, spec: spec(count: 5), excluding: [], check: eligible)
        let last = first.packages.compactMap { Draw.position(inSelection: $0.selection) }.max()!
        let more = await Draw.draw(repos: repos, spec: spec(count: 3, start: last + 1),
                                   excluding: Set(first.packages.map(\.id)), check: eligible)
        #expect((first.packages + more.packages).map(\.id) == Array(golden.prefix(8)))
    }

    /// D5: an extension must continue the same order, so every candidate must record this seed and frame.
    @Test func extensionMismatchRefusesADifferentSeedOrFrame() async {
        let r = await Draw.draw(repos: Draw.repos(fromPackageList: list), spec: spec(count: 3), excluding: [], check: eligible)
        let frame = "4dc1035a98457e87f4d2c5649a33cd43ee6b80e8"
        #expect(Draw.extensionMismatch(r.packages, seed: 20261004, packageListSHA: frame) == nil)
        #expect(Draw.extensionMismatch(r.packages, seed: 1, packageListSHA: frame) == r.packages[0].id)
        #expect(Draw.extensionMismatch(r.packages, seed: 20261004, packageListSHA: String(repeating: "c", count: 40)) == r.packages[0].id)
    }

    @Test func encodingKeepsDrawOrderAndIsByteStable() async throws {
        let r = await Draw.draw(repos: Draw.repos(fromPackageList: list), spec: spec(), excluding: [], check: eligible)
        let again = await Draw.draw(repos: Draw.repos(fromPackageList: list.reversed()), spec: spec(), excluding: [], check: eligible)
        let a = try CorpusYAML.encode(CorpusManifest(packages: r.packages), header: "# h\n")
        let b = try CorpusYAML.encode(CorpusManifest(packages: again.packages), header: "# h\n")
        #expect(a == b)
        #expect(a.hasPrefix("# h\n"))
        // Draw order (o/r18 before o/r12), not sorted order.
        #expect(a.range(of: "o/r18")!.lowerBound < a.range(of: "o/r12")!.lowerBound)
    }

    @Test func metadataRulesArePreRegistered() {
        let now = ISO8601DateFormatter().date(from: "2026-10-10T00:00:00Z")!
        #expect(Draw.checkMetadata("false\tfalse\t2026-09-01T00:00:00Z\tmain\n", now: now, activeDays: 365) == .active(branch: "main"))
        #expect(Draw.checkMetadata("true\tfalse\t2026-09-01T00:00:00Z\tmain", now: now, activeDays: 365) == .rejected("archived or disabled"))
        #expect(Draw.checkMetadata("false\ttrue\t2026-09-01T00:00:00Z\tmain", now: now, activeDays: 365) == .rejected("archived or disabled"))
        #expect(Draw.checkMetadata("false\tfalse\t2025-10-01T00:00:00Z\tmain", now: now, activeDays: 365) == .rejected("inactive > 365d"))
        #expect(Draw.checkMetadata(nil, now: now, activeDays: 365) == .rejected("unavailable (renamed/removed)"))
        #expect(Draw.checkMetadata("garbage", now: now, activeDays: 365) == .rejected("unavailable (renamed/removed)"))
    }

    @Test func positionIsParsedFromTheSelectionString() {
        #expect(Draw.position(inSelection: "seed=1 draw-position=123 PackageList@x") == 123)
        #expect(Draw.position(inSelection: "named anchor") == nil)
    }
}
