import CensusCore
import Foundation
import Testing

@testable import CensusRunner

@Suite struct ScreenSelectionTests {
    func cand(_ i: Int) -> CorpusPackage {
        CorpusPackage(id: "o/r\(i)", url: "https://github.com/o/r\(i)", sha: String(format: "%040x", i),
                      stratum: .screen, platforms: [.macosSPM], selection: "t")
    }
    func emitter(_ i: Int, count: Int, status: ScreenStatus = .emitter) -> ScreenResult {
        ScreenResult(packageId: "o/r\(i)", sha: String(format: "%040x", i), status: status, screenCount: count, batch: 1,
                     verifyScreenCount: count)
    }

    /// G1: the screened SHA is the measurement. It is kept, never re-resolved.
    @Test func keepsTheScreenedSHAAndRecordsTheScreen() throws {
        let cands = (1...60).map(cand)
        let s = try Screen.selectEmit(results: (1...60).map { emitter($0, count: $0) }, candidates: cands,
                                      screenId: "screen-2026-10-10", seed: 20261010, count: 30)
        #expect(s.entries.count == 30 && s.emitters == 60)
        #expect(s.perTertile[.head] == 10 && s.perTertile[.middle] == 10 && s.perTertile[.tail] == 10)
        for e in s.entries {
            let c = try #require(cands.first { $0.id == e.id })
            #expect(e.sha == c.sha && e.url == c.url && e.stratum == .emit && e.platforms == [.linuxSPM, .macosSPM])
            #expect(e.screenId == "screen-2026-10-10" && e.screenCountAtSelection != nil)
            #expect(e.spiErrorCountAtSelection == nil)
            #expect(e.selection.contains("seed=20261010") && e.selection.contains("screen-2026-10-10"))
        }
    }

    @Test func neverSelectsUnstableOrNonEmitters() throws {
        let rs = [emitter(1, count: 5), emitter(2, count: 9, status: .unstable),
                  ScreenResult(packageId: "o/r3", sha: "", status: .clean, screenCount: 0, batch: 1),
                  ScreenResult(packageId: "o/r4", sha: "", status: .notScreenable, reason: "build_failed", batch: 1)]
        let s = try Screen.selectEmit(results: rs, candidates: (1...4).map(cand), screenId: "x", seed: 1, count: 30)
        #expect(s.entries.map(\.id) == ["o/r1"] && s.emitters == 1)
    }

    @Test func refusesEmittersThatWereNeverVerified() {
        var r = emitter(1, count: 5)
        r.verifyScreenCount = nil
        #expect(throws: ScreenError.self) {
            try Screen.selectEmit(results: [r], candidates: [cand(1)], screenId: "x", seed: 1, count: 30)
        }
    }

    /// After a D5 `--extend` without re-collecting, results.json is older than candidates.yaml.
    @Test func refusesStaleResultsThatDoNotCoverEveryCandidate() {
        #expect(throws: ScreenError.self) {
            try Screen.selectEmit(results: (1...3).map { emitter($0, count: $0) }, candidates: (1...5).map(cand),
                                  screenId: "x", seed: 1, count: 30)
        }
    }

    @Test func refusesResultsForAnIdThatIsNotACandidate() {
        #expect(throws: ScreenError.self) {
            try Screen.selectEmit(results: [emitter(1, count: 3), emitter(9, count: 4)], candidates: [cand(1), cand(2)],
                                  screenId: "x", seed: 1, count: 30)
        }
    }

    @Test func refusesAnEmitterWithoutAScreenCount() {
        var r = emitter(1, count: 3)
        r.screenCount = nil
        #expect(throws: ScreenError.self) {
            try Screen.selectEmit(results: [r], candidates: [cand(1)], screenId: "x", seed: 1, count: 30)
        }
    }

    /// Fewer emitters than `count` yields exactly what exists, never padded.
    @Test func shortSampleReturnsEveryEmitterWithoutPadding() throws {
        let cands = (1...6).map(cand)
        let rs = [emitter(1, count: 9), emitter(2, count: 7), emitter(3, count: 5), emitter(4, count: 2),
                  ScreenResult(packageId: "o/r5", sha: "", status: .clean, screenCount: 0, batch: 1),
                  ScreenResult(packageId: "o/r6", sha: "", status: .unresolvable, reason: "x", batch: 1)]
        let s = try Screen.selectEmit(results: rs, candidates: cands, screenId: "x", seed: 1, count: 30)
        #expect(s.emitters == 4 && s.entries.count == 4)
        #expect(Set(s.entries.map(\.id)) == ["o/r1", "o/r2", "o/r3", "o/r4"])
        #expect(s.perTertile[.head] == 2 && s.perTertile[.middle] == 1 && s.perTertile[.tail] == 1)
    }

    func tempDirs() throws -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sel-\(UUID())")
        let src = base.appendingPathComponent("src"), dst = base.appendingPathComponent("dst")
        for d in [src, dst] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let prov = ["o/r1": ResolvedProvenance(source: "generated", toolchain: "6.4", resolvedAt: "2026-10-10T00:00:00Z", sha256: "s", pinCount: 2)]
        try RunStore(root: src).write(prov, to: src.appendingPathComponent("provenance.json"))
        try Data("{\n  \"pins\" : [ ],\n  \"version\" : 3\n}\n".utf8).write(to: src.appendingPathComponent("o__r1.resolved"))
        let existing = ["other/x": ResolvedProvenance(source: "upstream", toolchain: "6.4", resolvedAt: "x", sha256: "t", pinCount: 0)]
        try RunStore(root: dst).write(existing, to: dst.appendingPathComponent("provenance.json"))
        return (src, dst)
    }

    @Test func copiesResolvedBytesUnchangedAndMergesProvenance() throws {
        let (src, dst) = try tempDirs()
        try Screen.copyResolved([cand(1)], from: src, to: dst)
        #expect(try MatrixRun.sha256Hex(of: src.appendingPathComponent("o__r1.resolved"))
            == MatrixRun.sha256Hex(of: dst.appendingPathComponent("o__r1.resolved")))
        let prov = try JSONDecoder().decode([String: ResolvedProvenance].self, from: Data(contentsOf: dst.appendingPathComponent("provenance.json")))
        #expect(prov.keys.sorted() == ["o/r1", "other/x"])
        #expect(prov["o/r1"]?.source == "generated")
    }

    @Test func refusesToOverwriteADifferentPinnedFileAndWritesNothing() throws {
        let (src, dst) = try tempDirs()
        let target = dst.appendingPathComponent("o__r1.resolved")
        try Data("different".utf8).write(to: target)
        #expect(throws: ScreenError.self) { try Screen.copyResolved([cand(1)], from: src, to: dst) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "different")
        let prov = try JSONDecoder().decode([String: ResolvedProvenance].self, from: Data(contentsOf: dst.appendingPathComponent("provenance.json")))
        #expect(prov.keys.sorted() == ["other/x"])
    }
}
