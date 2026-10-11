import CensusCore
import Foundation
import Testing

@testable import CensusRunner

private let sha = String(repeating: "a", count: 40)

private func diag(_ line: Int) -> DiagnosticRecord {
    DiagnosticRecord(id: "x", text: "t", severity: .warning, group: nil, groupURL: nil, path: "Sources/A/a.swift",
                     line: line, col: 1, fixIts: 0, attribution: .primary, parent: nil)
}

private func entry(_ id: String) -> CorpusPackage {
    CorpusPackage(id: id, url: "https://github.com/\(id)", sha: sha, stratum: .emit, platforms: [.linuxSPM, .macosSPM],
                  selection: "t", screenId: "screen-2026-10-10", screenCountAtSelection: 1)
}

/// Screen cells carry `stratum: screen` and run cells `S-emit` (Review Focus 4): the check must not care.
private func cell(_ id: String, _ diags: [DiagnosticRecord], stratum: Stratum, mode: Mode = .strictCompleteV5,
                  sha cellSHA: String = sha, resolved: String? = "r1",
                  image: String? = "ipsw-sha256:g", xcode: String? = "27A266a") -> (RunStore.CellKey, RunStore.LoadedCell) {
    var r = CellRecord(packageId: id, sha: cellSHA, stratum: stratum, toolchain: "xcode-27.0", mode: mode,
                       platform: .macosSPM, outcome: .built, exitCode: 0, startedAt: "", durationSeconds: 0,
                       invocation: [], image: "lima:census-macos")
    r.resolvedFileSHA256 = resolved
    r.imageID = image
    r.xcodeBuild = xcode
    return (RunStore.CellKey(toolchain: "xcode-27.0", mode: mode, packageId: id),
            RunStore.LoadedCell(record: r, diagnostics: diags, directory: URL(fileURLWithPath: "/")))
}

private func cells(_ c: (RunStore.CellKey, RunStore.LoadedCell)...) -> [RunStore.CellKey: RunStore.LoadedCell] {
    Dictionary(uniqueKeysWithValues: c)
}

@Suite struct ScreenReproductionTests {
    let packages = [entry("o/a"), entry("o/b")]

    @Test func identicalCellsReproduceAndExtrasAreIgnored() {
        let screen = cells(cell("o/a", [diag(1)], stratum: .screen), cell("o/b", [], stratum: .screen),
                           cell("o/a", [diag(1)], stratum: .screen, mode: .minimalV5),
                           cell("x/not-selected", [diag(9)], stratum: .screen))
        let run = cells(cell("o/a", [diag(1)], stratum: .emit), cell("o/b", [], stratum: .emit),
                        cell("o/a", [diag(1)], stratum: .emit, mode: .strictCompleteDeclared))
        let r = ScreenReproduction.check(packages: packages, screenCells: screen, runCells: run)
        #expect(r.isReproduced)
        #expect(r.comparison?.cellsCompared == 2)
        #expect(r.ignoredScreenCells == 2)
        #expect(r.ignoredRunCells == 1)
    }

    @Test func aDifferingDiagnosticDoesNotReproduce() {
        let r = ScreenReproduction.check(packages: packages,
                                         screenCells: cells(cell("o/a", [diag(1)], stratum: .screen), cell("o/b", [], stratum: .screen)),
                                         runCells: cells(cell("o/a", [diag(2)], stratum: .emit), cell("o/b", [], stratum: .emit)))
        #expect(!r.isReproduced)
        #expect(r.comparison?.differing.count == 1)
    }

    @Test func aCellMissingFromTheRunDoesNotReproduce() {
        let r = ScreenReproduction.check(packages: packages,
                                         screenCells: cells(cell("o/a", [], stratum: .screen), cell("o/b", [], stratum: .screen)),
                                         runCells: cells(cell("o/a", [], stratum: .emit)))
        #expect(!r.isReproduced)
        #expect(r.comparison?.onlyInLeft.map(\.packageId) == ["o/b"])
    }

    @Test func differentInputsAreRefusedNotCompared() {
        let other = String(repeating: "b", count: 40)
        for run in [cells(cell("o/a", [], stratum: .emit, sha: other)),
                    cells(cell("o/a", [], stratum: .emit, resolved: "r2")),
                    cells(cell("o/a", [], stratum: .emit, image: "ipsw-sha256:other")),
                    cells(cell("o/a", [], stratum: .emit, xcode: "27B1"))] {
            let r = ScreenReproduction.check(packages: [entry("o/a")],
                                             screenCells: cells(cell("o/a", [], stratum: .screen)), runCells: run)
            #expect(!r.isReproduced)
            #expect(r.comparison == nil)
            #expect(r.inputMismatches.count == 1)
        }
    }

    @Test func anUnrecordedResolvedHashIsAMismatch() {
        let r = ScreenReproduction.check(packages: [entry("o/a")],
                                         screenCells: cells(cell("o/a", [], stratum: .screen, resolved: nil)),
                                         runCells: cells(cell("o/a", [], stratum: .emit, resolved: nil)))
        #expect(r.comparison == nil)
        #expect(r.inputMismatches.first?.field == "resolved_file_sha256")
    }
}
