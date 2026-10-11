import CensusCore
import Foundation
import Testing

@testable import CensusRunner

private func diag(severity: Severity = .warning, attribution: Attribution = .primary, line: Int = 1) -> DiagnosticRecord {
    DiagnosticRecord(id: "x", text: "t", severity: severity, group: nil, groupURL: nil, path: "Sources/A/a.swift",
                     line: line, col: 1, fixIts: 0, attribution: attribution, parent: nil)
}

/// 30 entries, 10 per tertile, ids o/p0 ... o/p29 (p0–p9 head, p10–p19 middle, p20–p29 tail).
private func emitEntry(_ i: Int) -> CorpusPackage {
    let tertile = ["head", "middle", "tail"][i / 10]
    return CorpusPackage(id: "o/p\(i)", url: "https://github.com/o/p\(i)", sha: String(repeating: "a", count: 40),
                         stratum: .emit, platforms: [.linuxSPM, .macosSPM],
                         selection: "seed=20261010 \(tertile)-tertile of 47 stable emitters; screen screen-2026-10-10 count 3")
}

private let population = (0..<30).map(emitEntry)

private func cell(_ id: String, toolchain: String = "6.4", _ outcome: CellOutcome = .built,
                  _ diags: [DiagnosticRecord] = [], mode: Mode = .strictCompleteV5,
                  platform: Platform = .linuxSPM, stratum: Stratum = .emit) -> (RunStore.CellKey, RunStore.LoadedCell) {
    let r = CellRecord(packageId: id, sha: String(repeating: "a", count: 40), stratum: stratum, toolchain: toolchain,
                       mode: mode, platform: platform, outcome: outcome, exitCode: 0, startedAt: "", durationSeconds: 0,
                       invocation: [], image: "")
    return (RunStore.CellKey(toolchain: toolchain, mode: mode, packageId: id),
            RunStore.LoadedCell(record: r, diagnostics: diags, directory: URL(fileURLWithPath: "/")))
}

/// Every one of the 30 has a `built` cell on `toolchain`; the first `n` (by index) carry one primary warning.
private func column(emitting n: Int, toolchain: String = "6.4") -> [RunStore.CellKey: RunStore.LoadedCell] {
    Dictionary(uniqueKeysWithValues: (0..<30).map { i in
        cell("o/p\(i)", toolchain: toolchain, .built, i < n ? [diag()] : [])
    })
}

private func with(_ base: [RunStore.CellKey: RunStore.LoadedCell],
                  _ cells: (RunStore.CellKey, RunStore.LoadedCell)...) -> [RunStore.CellKey: RunStore.LoadedCell] {
    base.merging(cells, uniquingKeysWith: { _, new in new })
}

@Suite struct G2ScoringTests {
    @Test func fifteenOfThirtyPasses() {
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: column(emitting: 15))
        #expect(r.verdict == .pass)
        #expect(r.gating?.emits == 15)
        #expect(r.reasons.isEmpty)
    }

    @Test func fourteenOfThirtyFails() {
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: column(emitting: 14))
        #expect(r.verdict == .fail)
        #expect(r.gating?.emits == 14)
    }

    @Test func buildFailedWithPrimaryErrorsDoesNotEmitButCountsAnyOutcome() {
        let cells = with(column(emitting: 15), cell("o/p20", .buildFailed, [diag(severity: .error)]))
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells)
        #expect(r.gating?.emits == 15)
        #expect(r.gating?.emitsAnyOutcome == 16)
        #expect(r.gating?.packages.first { $0.packageId == "o/p20" }?.emits == false)
    }

    @Test func notesAndNonPrimaryDoNotEmit() {
        let cells = with(column(emitting: 15),
                         cell("o/p20", .built, [diag(severity: .note)]),
                         cell("o/p21", .built, [diag(attribution: .transitive)]),
                         cell("o/p22", .built, [diag(attribution: .generated)]),
                         cell("o/p23", .built, [diag(attribution: .external)]))
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells)
        #expect(r.gating?.emits == 15)
        #expect(r.gating?.emitsAnyOutcome == 15)
    }

    @Test func otherOutcomesDoNotEmitButAreEvaluable() {
        let cells = with(column(emitting: 15),
                         cell("o/p20", .timeout), cell("o/p21", .unsupportedToolsVersion), cell("o/p22", .resolveFailed))
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells)
        #expect(r.verdict == .pass)
        #expect(r.gating?.packages.first { $0.packageId == "o/p21" }?.outcome == .unsupportedToolsVersion)
    }

    @Test func aMissingGatingCellIsNotEvaluable() {
        var cells = column(emitting: 30)
        cells[RunStore.CellKey(toolchain: "6.4", mode: .strictCompleteV5, packageId: "o/p29")] = nil
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells)
        #expect(r.verdict == .notEvaluable)
        #expect(r.gating?.missing == 1)
    }

    @Test func anInfraErrorGatingCellIsNotEvaluable() {
        let cells = with(column(emitting: 30), cell("o/p29", .infraError))
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells)
        #expect(r.verdict == .notEvaluable)
        #expect(r.gating?.infraError == 1)
    }

    @Test func aSkippedEntryMakesItNotEvaluable() {
        var skipped = population
        skipped[29].skipReason = "unresolvable"
        var cells = column(emitting: 30)
        cells[RunStore.CellKey(toolchain: "6.4", mode: .strictCompleteV5, packageId: "o/p29")] = nil
        let r = G2.evaluate(manifest: CorpusManifest(packages: skipped), cells: cells)
        #expect(r.verdict == .notEvaluable)
        #expect(r.population == 30)
    }

    @Test func gapsOnANonGatingColumnDoNotBlock() {
        var nightly = column(emitting: 10, toolchain: "nightly")
        nightly[RunStore.CellKey(toolchain: "nightly", mode: .strictCompleteV5, packageId: "o/p0")] = nil
        let r = G2.evaluate(manifest: CorpusManifest(packages: population),
                            cells: column(emitting: 20).merging(nightly, uniquingKeysWith: { a, _ in a }))
        #expect(r.verdict == .pass)
        let n = r.columns.first { $0.toolchain == "nightly" }
        #expect(n?.missing == 1)
        #expect(n?.emits == 9)
        #expect(r.columns.map(\.toolchain) == ["6.4", "nightly"])
    }

    @Test func otherStrataAndOtherModesAreIgnored() {
        let control = CorpusPackage(id: "c/ctl", url: "https://github.com/c/ctl", sha: String(repeating: "b", count: 40),
                                    stratum: .control, platforms: [.linuxSPM], selection: "t")
        let cells = with(column(emitting: 14),
                         cell("c/ctl", .built, [diag()], stratum: .control),
                         cell("o/p20", .built, [diag()], mode: .strictCompleteDeclared))
        let r = G2.evaluate(manifest: CorpusManifest(packages: population + [control]), cells: cells)
        #expect(r.verdict == .fail)
        #expect(r.gating?.emits == 14)
        #expect(r.population == 30)
    }

    @Test func aPopulationOtherThanThirtyIsNotEvaluable() {
        let r = G2.evaluate(manifest: CorpusManifest(packages: Array(population.prefix(29))), cells: column(emitting: 29))
        #expect(r.verdict == .notEvaluable)
    }

    @Test func anEntryWithoutATertileIsNotEvaluable() {
        var untagged = population
        untagged[0].selection = "hand-picked"
        let r = G2.evaluate(manifest: CorpusManifest(packages: untagged), cells: column(emitting: 30))
        #expect(r.verdict == .notEvaluable)
    }

    @Test func aMacOSCellIsNotEvaluable() {
        let cells = with(column(emitting: 30), cell("o/p0", .built, [diag()], platform: .macosSPM))
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells)
        #expect(r.verdict == .notEvaluable)
    }

    @Test func countsPerTertile() {
        // p0–p9 head all emit, p10–p14 middle emit, tail none.
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: column(emitting: 15))
        #expect(r.gating?.byTertile["head"] == G2.TertileCount(emits: 10, total: 10))
        #expect(r.gating?.byTertile["middle"] == G2.TertileCount(emits: 5, total: 10))
        #expect(r.gating?.byTertile["tail"] == G2.TertileCount(emits: 0, total: 10))
    }

    @Test func reportEncodesSnakeCase() throws {
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: column(emitting: 15))
        let json = String(decoding: try RunStore.encoder().encode(r), as: UTF8.self)
        #expect(json.contains("\"emits_any_outcome\""))
        #expect(json.contains("\"gating_toolchain\" : \"6.4\""))
        #expect(json.contains("\"verdict\" : \"pass\""))
        #expect(try JSONDecoder().decode(G2.Report.self, from: Data(json.utf8)) == r)
    }
}

@Suite struct G2RenderTests {
    @Test func endsWithTheVerdictAndMarksTheGatingColumn() {
        let pass = G2.render(G2.evaluate(manifest: CorpusManifest(packages: population), cells: column(emitting: 15)))
        #expect(pass.last == "G2 PASS")
        #expect(pass.contains { $0.hasPrefix("6.4 [gating]: 15/30 emit (50.0%)") })
        let fail = G2.render(G2.evaluate(manifest: CorpusManifest(packages: population), cells: column(emitting: 14)))
        #expect(fail.last == "G2 FAIL")
        let none = G2.render(G2.evaluate(manifest: CorpusManifest(packages: population), cells: [:]))
        #expect(none.last == "G2 NOT EVALUABLE")
        #expect(none.contains { $0.hasPrefix("not evaluable: 30 S-emit cells missing on 6.4") })
    }

    @Test func listsEveryNonEmittingGatingPackageWithItsOutcome() {
        let cells = with(column(emitting: 29), cell("o/p29", .buildFailed, [diag(severity: .error)]))
        let lines = G2.render(G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells))
        #expect(lines.contains("  not emitting on 6.4: o/p29 [tail] build_failed, primary non-note 1"))
        #expect(lines.filter { $0.hasPrefix("  not emitting") }.count == 1)
    }
}
