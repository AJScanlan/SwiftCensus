import CensusCore
import Foundation
import Testing

@testable import CensusRunner

private func diag(_ id: String?, line: Int = 1, text: String = "t", severity: Severity = .warning,
                  attribution: Attribution = .primary) -> DiagnosticRecord {
    DiagnosticRecord(id: id, text: text, severity: severity, group: nil, groupURL: nil, path: "Sources/A/a.swift",
                     line: line, col: 1, fixIts: 0, attribution: attribution, parent: nil)
}

private func pkg(_ id: String) -> CorpusPackage {
    CorpusPackage(id: id, url: "https://github.com/\(id)", sha: String(repeating: "c", count: 40),
                  stratum: .screen, platforms: [.macosSPM], selection: "t")
}

private func cell(_ mode: Mode, _ outcome: CellOutcome, _ diags: [DiagnosticRecord] = [],
                  id: String = "o/r", note: String? = nil,
                  sha: String = String(repeating: "c", count: 40)) -> RunStore.LoadedCell {
    var r = CellRecord(packageId: id, sha: sha, stratum: .screen, toolchain: "xcode-27.0",
                       mode: mode, platform: .macosSPM, outcome: outcome, exitCode: 0, startedAt: "", durationSeconds: 0,
                       invocation: [], image: "")
    r.note = note
    return RunStore.LoadedCell(record: r, diagnostics: diags, directory: URL(fileURLWithPath: "/"))
}

@Suite struct ScreenCountTests {
    @Test func identicalBuildsCountZero() {
        let d = [diag("a"), diag("b", line: 2)]
        #expect(Screen.screenCount(complete: d, minimal: d) == 0)
    }

    @Test func countsWhatCompleteAdds() {
        let base = [diag("a")]
        #expect(Screen.screenCount(complete: base + [diag("x", line: 2), diag("y", line: 3), diag("z", line: 4)], minimal: base) == 3)
    }

    @Test func aMovedLineCountsAsAdded() {
        #expect(Screen.screenCount(complete: [diag("a", line: 2)], minimal: [diag("a", line: 1)]) == 1)
    }

    @Test func isAMultisetDifferenceLeftMinusRight() {
        #expect(Screen.screenCount(complete: [diag("a"), diag("a")], minimal: [diag("a")]) == 1)
        #expect(Screen.screenCount(complete: [], minimal: [diag("a")]) == 0)
    }

    @Test func notesAndNonPrimaryAreIgnored() {
        let ignored = [diag("n", line: 9, severity: .note), diag("d", attribution: .transitive),
                       diag("g", attribution: .generated), diag("e", attribution: .external)]
        #expect(Screen.screenCount(complete: ignored, minimal: []) == 0)
    }

    /// Unlike the A7 key, severity is not part of the count key (ADR 0007).
    @Test func aSeverityChangeBetweenModesIsNotADifference() {
        #expect(Screen.screenCount(complete: [diag("a", severity: .error)], minimal: [diag("a", severity: .warning)]) == 0)
    }

    @Test func isOrderIndependent() {
        let c = [diag("a"), diag("b", line: 2), diag("c", line: 3)]
        #expect(Screen.screenCount(complete: c, minimal: [diag("b", line: 2)])
            == Screen.screenCount(complete: c.reversed(), minimal: [diag("b", line: 2)]))
    }

    @Test func aMissingIdFallsBackToText() {
        #expect(Screen.screenCount(complete: [diag(nil, text: "x")], minimal: [diag(nil, text: "y")]) == 1)
        #expect(Screen.screenCount(complete: [diag(nil, text: "x")], minimal: [diag(nil, text: "x")]) == 0)
    }
}

@Suite struct ScreenClassificationTests {
    let p = pkg("o/r")

    @Test func emitter() throws {
        let r = try Screen.classify(package: p, batch: 2, resolveFailure: nil,
                                    complete: cell(.strictCompleteV5, .built, [diag("a"), diag("b", line: 2)]),
                                    minimal: cell(.minimalV5, .built, [diag("a")]))
        #expect(r.status == .emitter && r.screenCount == 1 && r.batch == 2 && r.sha == p.sha)
        #expect(r.completePrimaryDiagnostics == 2 && r.minimalPrimaryDiagnostics == 1)
        #expect(r.completeOutcome == .built && r.minimalOutcome == .built)
    }

    @Test func cleanWithNoPrimaryDiagnosticsNeedsNoMinimalBuild() throws {
        let complete = cell(.strictCompleteV5, .built, [diag("n", severity: .note), diag("d", attribution: .transitive)])
        #expect(!Screen.needsMinimal(complete))
        let r = try Screen.classify(package: p, batch: 1, resolveFailure: nil, complete: complete, minimal: nil)
        #expect(r.status == .clean && r.screenCount == 0 && r.minimalOutcome == nil)
    }

    @Test func cleanWhenMinimalAlreadyHasEverything() throws {
        let d = [diag("a")]
        #expect(Screen.needsMinimal(cell(.strictCompleteV5, .built, d)))
        let r = try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                    complete: cell(.strictCompleteV5, .built, d), minimal: cell(.minimalV5, .built, d))
        #expect(r.status == .clean && r.screenCount == 0)
    }

    @Test(arguments: [CellOutcome.buildFailed, .unsupportedToolsVersion, .resolveFailed, .timeout])
    func notScreenableKeepsReasonAndTally(outcome: CellOutcome) throws {
        let complete = cell(.strictCompleteV5, outcome, [diag("a")])
        #expect(!Screen.needsMinimal(complete))
        let r = try Screen.classify(package: p, batch: 1, resolveFailure: nil, complete: complete, minimal: nil)
        #expect(r.status == .notScreenable && r.reason == outcome.rawValue)
        #expect(r.completePrimaryDiagnostics == 1 && r.screenCount == nil)
    }

    @Test func minimalFailed() throws {
        let r = try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                    complete: cell(.strictCompleteV5, .built, [diag("a")]), minimal: cell(.minimalV5, .buildFailed))
        #expect(r.status == .minimalFailed && r.reason == "build_failed" && r.screenCount == nil)
    }

    @Test func unresolvable() throws {
        let r = try Screen.classify(package: p, batch: 3, resolveFailure: "o/r: dependency resolution failed", complete: nil, minimal: nil)
        #expect(r.status == .unresolvable && r.reason == "o/r: dependency resolution failed" && r.completeOutcome == nil && r.batch == 3)
    }

    @Test func infraErrorOnEitherCell() throws {
        let a = try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                    complete: cell(.strictCompleteV5, .infraError, note: "corrupt .dia"), minimal: nil)
        #expect(a.status == .infraError && a.reason == "corrupt .dia")
        let b = try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                    complete: cell(.strictCompleteV5, .built, [diag("a")]), minimal: cell(.minimalV5, .infraError))
        #expect(b.status == .infraError)
    }

    @Test func aSwappedOrForeignCellNeverYieldsACount() {
        let d = [diag("a"), diag("b", line: 2)]
        #expect(throws: ScreenError.self) {
            try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                complete: cell(.minimalV5, .built, d), minimal: cell(.minimalV5, .built, [diag("a")]))
        }
        #expect(throws: ScreenError.self) {
            try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                complete: cell(.strictCompleteV5, .built, d), minimal: cell(.minimalV5, .built, [diag("a")], id: "o/other"))
        }
        #expect(throws: ScreenError.self) {
            try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                complete: cell(.strictCompleteV5, .built, d, id: "o/other"), minimal: cell(.minimalV5, .built, [diag("a")]))
        }
    }

    /// A cell built from another commit of the same package (candidates re-drawn, or a stale run directory) is not
    /// a measurement of this candidate.
    @Test func aCellBuiltAtADifferentSHAIsRefused() {
        let other = String(repeating: "d", count: 40)
        let d = [diag("a"), diag("b", line: 2)]
        #expect(throws: ScreenError.self) {
            try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                complete: cell(.strictCompleteV5, .built, d, sha: other), minimal: cell(.minimalV5, .built, [diag("a")]))
        }
        #expect(throws: ScreenError.self) {
            try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                complete: cell(.strictCompleteV5, .built, d), minimal: cell(.minimalV5, .built, [diag("a")], sha: other))
        }
        // The message names both SHAs.
        do {
            _ = try Screen.classify(package: p, batch: 1, resolveFailure: nil, complete: cell(.strictCompleteV5, .built, d, sha: other), minimal: nil)
            Issue.record("expected a throw")
        } catch {
            #expect("\(error)".contains(other) && "\(error)".contains(p.sha))
        }
    }

    @Test func aMissingCellIsAnErrorNeverASilentGap() {
        #expect(throws: ScreenError.self) {
            try Screen.classify(package: p, batch: 1, resolveFailure: nil, complete: nil, minimal: nil)
        }
        #expect(throws: ScreenError.self) {
            try Screen.classify(package: p, batch: 1, resolveFailure: nil, complete: cell(.strictCompleteV5, .built, [diag("a")]), minimal: nil)
        }
    }
}

@Suite struct ScreenStabilityTests {
    let p = pkg("o/r")
    func pass1() throws -> ScreenResult {
        try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                            complete: cell(.strictCompleteV5, .built, [diag("a"), diag("b", line: 2)]), minimal: cell(.minimalV5, .built, [diag("a")]))
    }

    @Test func agreeingVerifyPassStaysAnEmitter() throws {
        let r = try Screen.applyVerify(try pass1(), package: p,
                                       complete: cell(.strictCompleteV5, .built, [diag("a"), diag("b", line: 2)]),
                                       minimal: cell(.minimalV5, .built, [diag("a")]))
        #expect(r.status == .emitter && r.verifyScreenCount == 1)
    }

    @Test func aDifferentCountIsUnstable() throws {
        let r = try Screen.applyVerify(try pass1(), package: p,
                                       complete: cell(.strictCompleteV5, .built, [diag("a"), diag("b", line: 2), diag("c", line: 3)]),
                                       minimal: cell(.minimalV5, .built, [diag("a")]))
        #expect(r.status == .unstable && r.verifyScreenCount == 2 && r.screenCount == 1)
    }

    @Test func aDifferentOutcomeIsUnstable() throws {
        let r = try Screen.applyVerify(try pass1(), package: p, complete: cell(.strictCompleteV5, .buildFailed, [diag("a")]), minimal: nil)
        #expect(r.status == .unstable)
    }

    /// A machine fault is retried, never recorded as package instability.
    @Test func aVerifyInfraErrorIsRetriedNotUnstable() throws {
        #expect(throws: ScreenError.self) {
            try Screen.applyVerify(try pass1(), package: p, complete: cell(.strictCompleteV5, .infraError), minimal: nil)
        }
        #expect(throws: ScreenError.self) {
            try Screen.applyVerify(try pass1(), package: p,
                                   complete: cell(.strictCompleteV5, .built, [diag("a"), diag("b", line: 2)]),
                                   minimal: cell(.minimalV5, .infraError))
        }
    }

    @Test func nonEmittersAreReturnedUnchanged() throws {
        let clean = ScreenResult(packageId: "o/r", sha: "", status: .clean, screenCount: 0, batch: 1)
        #expect(try Screen.applyVerify(clean, package: p, complete: nil, minimal: nil) == clean)
    }

    @Test func aMissingVerifyCellIsAnError() {
        #expect(throws: ScreenError.self) { try Screen.applyVerify(try pass1(), package: p, complete: nil, minimal: nil) }
    }

    @Test func verifyPassCoversPassOneEmittersInCandidateOrder() {
        let cands = [pkg("o/a"), pkg("o/b"), pkg("o/c"), pkg("o/d")]
        let rs = [ScreenResult(packageId: "o/c", sha: "", status: .unstable, batch: 1),
                  ScreenResult(packageId: "o/a", sha: "", status: .emitter, batch: 1),
                  ScreenResult(packageId: "o/b", sha: "", status: .clean, batch: 1),
                  ScreenResult(packageId: "o/d", sha: "", status: .notScreenable, batch: 1)]
        #expect(Screen.verifyPackages(results: rs, candidates: cands).map(\.id) == ["o/a", "o/c"])
    }
}

@Suite struct ScreenBookkeepingTests {
    func res(_ id: String, _ s: ScreenStatus, reason: String? = nil, count: Int? = nil) -> ScreenResult {
        ScreenResult(packageId: id, sha: "", status: s, reason: reason, screenCount: count, batch: 1)
    }

    @Test func everyStatusIsCountedAndTheTableSumsToTheDraw() throws {
        let rs = ScreenStatus.allCases.enumerated().map { i, s in res("o/\(i)", s, reason: s == .notScreenable ? "build_failed" : nil) }
        let d = try Screen.denominator(drawn: rs.count, results: rs)
        #expect(d.total == rs.count)
        for s in ScreenStatus.allCases { #expect(d.byStatus[s] == 1) }
        #expect(d.notScreenableByReason == ["build_failed": 1])
        for s in ScreenStatus.allCases { #expect(d.rendered.contains(s.rawValue)) }
        #expect(d.rendered.contains("build_failed"))
    }

    @Test func aMissingOrDuplicatedCandidateFailsTheAssertion() {
        #expect(throws: ScreenError.denominatorMismatch(drawn: 3, sum: 2)) {
            try Screen.denominator(drawn: 3, results: [res("o/a", .clean), res("o/b", .emitter)])
        }
        #expect(throws: ScreenError.duplicateResults("o/a")) {
            try Screen.denominator(drawn: 2, results: [res("o/a", .clean), res("o/a", .clean)])
        }
    }

    @Test func emittersCSVRoundTripsThroughTheSPIParserAndOmitsUnstable() throws {
        let cands = [pkg("o/a"), pkg("o/b"), pkg("o/c")]
        let rs = [res("o/a", .emitter, count: 7), res("o/b", .clean, count: 0), res("o/c", .unstable, count: 4)]
        let rows = try Selection.parseSPICSV(Screen.emittersCSV(results: rs, candidates: cands, asOf: "2026-10-10"))
        #expect(rows == [SPIRow(url: "https://github.com/o/a", errors: 7, swiftVersion: "xcode-27.0-minimal-diff", asOf: "2026-10-10")])
    }

    @Test func screenDateComesFromTheId() {
        #expect(Screen.date(fromScreenId: "screen-2026-10-10") == "2026-10-10")
        #expect(Screen.date(fromScreenId: "dryrun-2026-10-10") == "2026-10-10")
        #expect(Screen.date(fromScreenId: "screen") == nil)
        #expect(Screen.date(fromScreenId: "screen-2026-1x-10") == nil)
    }

    /// Batch membership depends only on position, so a D5 extension never changes a full earlier batch.
    @Test func batchesArePositionalSoAnExtensionOnlyAppends() {
        let items = Array(0..<120)
        #expect(Screen.batchCount(120) == 3 && Screen.batchCount(100) == 2 && Screen.batchCount(0) == 0)
        #expect(Screen.batch(1, of: items) == Array(0..<50))
        #expect(Screen.batch(3, of: items) == Array(100..<120))
        #expect(Screen.batch(4, of: items).isEmpty && Screen.batch(0, of: items).isEmpty)
        let extended = items + Array(120..<270)
        for n in 1...2 { #expect(Screen.batch(n, of: extended) == Screen.batch(n, of: items)) }
    }

    @Test func cellsUseTheScreenToolchainAndTheRequestedMode() {
        let cells = Screen.cells([pkg("o/a"), pkg("o/b")], mode: .minimalV5)
        #expect(cells.map(\.package.id) == ["o/a", "o/b"])
        #expect(cells.allSatisfy { $0.mode == .minimalV5 && $0.toolchain == Toolchain.macOSXcode })
    }
}

@Suite struct ScreenDrawCountTests {
    @Test func freshDrawDefaultsTo300AndAcceptsAnExplicitCount() throws {
        #expect(try Screen.drawCount(requested: nil, extend: false) == 300)
        #expect(try Screen.drawCount(requested: 20, extend: false) == 20)
    }

    /// D5 pre-registers exactly one extension of +150; a forgotten `--count` must never become +300.
    @Test func extensionMustStateExactly150() throws {
        #expect(try Screen.drawCount(requested: 150, extend: true) == 150)
        #expect(throws: (any Error).self) { try Screen.drawCount(requested: nil, extend: true) }
        #expect(throws: (any Error).self) { try Screen.drawCount(requested: 300, extend: true) }
        #expect(throws: (any Error).self) { try Screen.drawCount(requested: 100, extend: true) }
    }
}
