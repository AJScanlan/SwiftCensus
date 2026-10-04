import CensusCore
import Foundation
import Testing

@testable import CensusRunner

@Suite struct OutcomeClassifierTests {
    let compileLine = "/usr/bin/swiftc -module-name Yams -Xfrontend x -strict-concurrency=complete -swift-version 5 -c a.swift"
    let manifestLine = "/usr/bin/swift-frontend -frontend -c -primary-file /pkg/Package.swift -module-name main -o /tmp/Package-1.o"

    @Test func exitZeroIsBuilt() {
        #expect(OutcomeClassifier.classify(exitCode: 0, timedOut: false, log: "") == .built)
    }

    @Test func sigkillIsInfraNotAPackageFailure() {
        #expect(OutcomeClassifier.classify(exitCode: 137, timedOut: false, log: "") == .infraError)
    }

    @Test func timeoutWinsOverEverything() {
        #expect(OutcomeClassifier.classify(exitCode: 0, timedOut: true, log: "") == .timeout)
    }

    @Test func newerToolsVersionIsNotAFailure() {
        let log = "error: package 'x' is using Swift tools version 6.2.0 but the installed version is 6.1.3"
        #expect(OutcomeClassifier.classify(exitCode: 1, timedOut: false, log: log) == .unsupportedToolsVersion)
    }

    @Test func resolutionFailureBeforeAnyCompileIsResolveFailed() {
        let log = "\(manifestLine)\nerror: Dependencies could not be resolved because of a conflict"
        #expect(OutcomeClassifier.classify(exitCode: 1, timedOut: false, log: log) == .resolveFailed)
    }

    /// A failed build still produced diagnostics; "out-of-date" appearing in a compile error must
    /// not demote it to a resolve failure.
    @Test func resolutionMarkerAfterCompileStartedIsBuildFailed() {
        let log = "\(compileLine)\nerror: something is out-of-date"
        #expect(OutcomeClassifier.classify(exitCode: 1, timedOut: false, log: log) == .buildFailed)
    }

    @Test func plainCompileFailureIsBuildFailed() {
        #expect(OutcomeClassifier.classify(exitCode: 1, timedOut: false, log: "\(compileLine)\nerror: boom") == .buildFailed)
    }

    @Test func frontendSampleSkipsTheManifestCompile() {
        let sample = OutcomeClassifier.frontendInvocationSample(in: "\(manifestLine)\n\(compileLine)\n")
        #expect(sample == compileLine)
        #expect(OutcomeClassifier.frontendInvocationSample(in: manifestLine) == nil)
    }

    @Test func parsesTripleAndVersion() {
        let text = "Swift version 6.3.3 (swift-6.3.3-RELEASE)\nTarget: aarch64-unknown-linux-gnu\naarch64\n"
        #expect(OutcomeClassifier.targetTriple(inVersionOutput: text) == "aarch64-unknown-linux-gnu")
        #expect(OutcomeClassifier.toolchainVersion(inVersionOutput: text) == "Swift version 6.3.3 (swift-6.3.3-RELEASE)")
    }
}

@Suite struct BuildInvocationTests {
    @Test func v5ForcesSwiftVersionFive() {
        let args = BuildInvocation.swiftBuildArguments(mode: .strictCompleteV5)
        let i = args.firstIndex(of: "-swift-version")
        #expect(i != nil && args[i! + 2] == "5")
        #expect(args.contains("--force-resolved-versions"))
        #expect(args.contains("-strict-concurrency=complete"))
        #expect(args.contains("-debug-diagnostic-names"))
        #expect(!args.contains("--build-tests"))
    }

    @Test func declaredModeDoesNotForceSwiftVersion() {
        let args = BuildInvocation.swiftBuildArguments(mode: .strictCompleteDeclared)
        #expect(!args.contains("-swift-version"))
        #expect(args.contains("-strict-concurrency=complete"))
    }

    @Test func onlyAnchorsGetTheDeclaredOverlay() {
        #expect(BuildInvocation.modes(for: .anchor) == [.strictCompleteV5, .strictCompleteDeclared])
        for s in [Stratum.emit, .control, .byproduct] { #expect(BuildInvocation.modes(for: s) == [.strictCompleteV5]) }
    }
}

@Suite struct PlanTests {
    func pkg(_ id: String, _ s: Stratum, platforms: [Platform] = [.linuxSPM], skip: String? = nil) -> CorpusPackage {
        CorpusPackage(id: id, url: "https://github.com/\(id)", sha: String(repeating: "a", count: 40),
                      stratum: s, platforms: platforms, selection: "test", skipReason: skip)
    }

    @Test func planSkipsSkippedAndNonLinuxPackages() {
        let m = CorpusManifest(packages: [
            pkg("a/a", .emit), pkg("b/b", .emit, platforms: [.macosSPM]), pkg("c/c", .emit, skip: "needs Apple SDK"),
        ])
        let cells = MatrixRun.plan(manifest: m, selection: MatrixSelection(toolchains: [Toolchain.matrix[0]]))
        #expect(cells.map(\.package.id) == ["a/a"])
    }

    @Test func anchorProducesTwoCellsPerToolchain() {
        let m = CorpusManifest(packages: [pkg("a/a", .anchor), pkg("b/b", .emit)])
        let cells = MatrixRun.plan(manifest: m, selection: MatrixSelection(toolchains: Array(Toolchain.matrix.prefix(2))))
        #expect(cells.count == 2 * (2 + 1))
    }

    @Test func fiveToolchainMatrixIsTheDefault() {
        #expect(Toolchain.matrix.map(\.name) == ["6.1", "6.2", "6.3", "6.4", "nightly"])
    }
}

@Suite struct ContainerScriptTests {
    @Test func scriptAlwaysExitsZeroAndRecordsBuildExitCode() {
        let s = CellRunner.script(arguments: ["swift", "build"])
        #expect(s.contains("echo $? > /out/exit-code"))
        #expect(s.hasSuffix("exit 0"))
    }

    @Test func quotingSurvivesSingleQuotes() {
        #expect(CellRunner.quote("it's") == "'it'\\''s'")
    }
}

@Suite struct RunComparisonTests {
    func rec(_ id: String, line: Int = 1, attribution: Attribution = .primary) -> DiagnosticRecord {
        DiagnosticRecord(id: id, text: "", severity: .warning, group: nil, groupURL: nil, path: "Sources/a.swift",
                         line: line, col: 1, fixIts: 0, attribution: attribution, parent: nil)
    }

    func cell(_ pkgId: String, outcome: CellOutcome = .built, _ diags: [DiagnosticRecord]) -> (RunStore.CellKey, RunStore.LoadedCell) {
        let r = CellRecord(packageId: pkgId, sha: "", stratum: .emit, toolchain: "6.3", mode: .strictCompleteV5,
                           platform: .linuxSPM, outcome: outcome, exitCode: 0, startedAt: "", durationSeconds: 0,
                           invocation: [], image: "")
        return (RunStore.CellKey(toolchain: "6.3", mode: .strictCompleteV5, packageId: pkgId),
                RunStore.LoadedCell(record: r, diagnostics: diags, directory: URL(fileURLWithPath: "/")))
    }

    func run(_ cells: (RunStore.CellKey, RunStore.LoadedCell)...) -> [RunStore.CellKey: RunStore.LoadedCell] {
        Dictionary(uniqueKeysWithValues: cells)
    }

    @Test func reorderedAndTransitiveOnlyChangesAreStillSetIdentical() {
        let a = run(cell("p", [rec("x", line: 1), rec("y", line: 2)]))
        let b = run(cell("p", [rec("y", line: 2), rec("x", line: 1), rec("dep", attribution: .transitive)]))
        #expect(RunComparison.compare(a, b).isSetIdentical)
    }

    @Test func aMovedLineIsADifference() {
        let r = RunComparison.compare(run(cell("p", [rec("x", line: 1)])), run(cell("p", [rec("x", line: 2)])))
        #expect(!r.isSetIdentical && r.differing.count == 1)
    }

    @Test func missingCellsAndOutcomeChangesAreNeverSilentlyIgnored() {
        let a = run(cell("p", [rec("x")]), cell("q", [rec("x")]))
        let b = run(cell("p", outcome: .timeout, []))
        let r = RunComparison.compare(a, b)
        #expect(r.outcomeMismatches.count == 1)
        #expect(r.onlyInLeft.map(\.packageId) == ["q"])
        #expect(!r.isSetIdentical)
    }

    @Test func equalNonDiagnosticOutcomesAreComparableButCountedApart() {
        let a = run(cell("p", outcome: .unsupportedToolsVersion, []))
        let r = RunComparison.compare(a, a)
        #expect(r.isSetIdentical && r.noDiagnosticCells == 1 && r.identical == 0)
    }
}
