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

    @Test func truncatedDiaInvalidatesOnlyCellsThatClaimDiagnostics() {
        #expect(OutcomeClassifier.truncatedDiaInvalidatesCell(outcome: .built))
        #expect(OutcomeClassifier.truncatedDiaInvalidatesCell(outcome: .buildFailed))
        #expect(!OutcomeClassifier.truncatedDiaInvalidatesCell(outcome: .timeout))
        #expect(!OutcomeClassifier.truncatedDiaInvalidatesCell(outcome: .unsupportedToolsVersion))
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

    /// An iOS-only package on macOS: the dependency scan cannot find UIKit. Not a SwiftPM resolution failure.
    @Test func missingModuleDuringDependencyScanIsBuildFailedNotResolveFailed() {
        let log = "error: /pkg/Sources/A/A.swift:9:8 unable to resolve module dependency: 'UIKit' [dependency_scan_module_not_found]\nerror: Build failed"
        #expect(OutcomeClassifier.classify(exitCode: 1, timedOut: false, log: log) == .buildFailed)
    }

    @Test func reclassifyKeepsOutcomesThatTheLogCannotRecover() {
        var r = CellRecord(packageId: "a/a", sha: "", stratum: .control, toolchain: "6.3", mode: .strictCompleteV5,
                           platform: .linuxSPM, outcome: .timeout, exitCode: nil, startedAt: "", durationSeconds: 0,
                           invocation: [], image: "")
        #expect(OutcomeClassifier.reclassify(r, log: "error: boom") == .timeout)
        r.outcome = .resolveFailed
        r.exitCode = 1
        #expect(OutcomeClassifier.reclassify(r, log: "unable to resolve module dependency: 'UIKit'") == .buildFailed)
    }

    @Test func plainCompileFailureIsBuildFailed() {
        #expect(OutcomeClassifier.classify(exitCode: 1, timedOut: false, log: "\(compileLine)\nerror: boom") == .buildFailed)
    }

    @Test func frontendSampleSkipsTheManifestCompile() {
        let sample = OutcomeClassifier.frontendInvocationSample(in: "\(manifestLine)\n\(compileLine)\n")
        #expect(sample == compileLine)
        #expect(OutcomeClassifier.frontendInvocationSample(in: manifestLine) == nil)
    }

    /// A minimal-v5 compile must count as "compile started": otherwise its F7 sample is nil and a failure
    /// mentioning "out-of-date" is misfiled as a resolve failure.
    @Test func minimalModeCompileLineIsRecognised() {
        let minimal = compileLine.replacingOccurrences(of: "=complete", with: "=minimal")
        #expect(OutcomeClassifier.frontendInvocationSample(in: "\(manifestLine)\n\(minimal)\n") == minimal)
        #expect(OutcomeClassifier.classify(exitCode: 1, timedOut: false, log: "\(minimal)\nerror: something is out-of-date") == .buildFailed)
    }

    /// macOS SwiftPM (Swift Build) logs the compile line with `=` escaped as `\=`. Without recognising it
    /// the F7 sample is nil on every macOS cell and a build failure is misfiled as a resolve failure.
    let escapedMacLine = "    builtin-SwiftDriver -- /Applications/Xcode-27.0.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -parse-as-library -module-name IDKit -Onone @/Users/aj.guest/pkg/.build/out/Intermediates.noindex/IDKit.build/Debug/IDKit-t.build/Objects-normal/arm64/IDKit.SwiftFileList -DSWIFT_PACKAGE -DDEBUG -DSWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE -DXcode -strict-concurrency\\=complete -swift-version 5 -debug-diagnostic-names"

    @Test func swiftBuildEscapedEqualsIsRecognised() {
        for escaped in [escapedMacLine, escapedMacLine.replacingOccurrences(of: "=complete", with: "=minimal")] {
            #expect(escaped.contains("strict-concurrency\\="))
            #expect(OutcomeClassifier.frontendInvocationSample(in: "\(manifestLine)\n\(escaped)\n") == escaped)
        }
        #expect(OutcomeClassifier.frontendInvocationSample(in: manifestLine) == nil)
    }

    @Test func swiftBuildEscapedCompileLineMakesMarkerFailureBuildFailed() {
        let log = "\(escapedMacLine)\nerror: something is out-of-date"
        #expect(OutcomeClassifier.classify(exitCode: 1, timedOut: false, log: log) == .buildFailed)
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
        // Pre-6.2 native builds emit no .dia unless asked; without it a cell silently reports zero.
        #expect(args.contains("-serialize-diagnostics"))
    }

    @Test func declaredModeDoesNotForceSwiftVersion() {
        let args = BuildInvocation.swiftBuildArguments(mode: .strictCompleteDeclared)
        #expect(!args.contains("-swift-version"))
        #expect(args.contains("-strict-concurrency=complete"))
    }

    @Test func minimalModeIsMinimalAndStillForcesSwiftVersionFive() {
        let args = BuildInvocation.swiftBuildArguments(mode: .minimalV5)
        #expect(args.contains("-strict-concurrency=minimal"))
        #expect(!args.contains { $0.contains("complete") })
        let i = args.firstIndex(of: "-swift-version")
        #expect(i != nil && args[i! + 2] == "5")
        #expect(args.contains("-debug-diagnostic-names") && args.contains("-serialize-diagnostics"))
    }

    /// The differential (ADR 0007) is only meaningful if the two builds differ in nothing but the checking level.
    @Test func minimalDiffersFromV5OnlyInTheConcurrencyLevel() {
        let v5 = BuildInvocation.swiftBuildArguments(mode: .strictCompleteV5)
        let minimal = BuildInvocation.swiftBuildArguments(mode: .minimalV5)
        #expect(minimal == v5.map { $0 == "-strict-concurrency=complete" ? "-strict-concurrency=minimal" : $0 })
    }

    @Test func onlyAnchorsGetTheDeclaredOverlay() {
        #expect(BuildInvocation.modes(for: .anchor) == [.strictCompleteV5, .strictCompleteDeclared])
        for s in [Stratum.emit, .control, .byproduct, .screen] { #expect(BuildInvocation.modes(for: s) == [.strictCompleteV5]) }
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

@Suite struct MacRunnerTests {
    @Test func macScriptUsesGuestPathsAndAlwaysExitsZero() {
        let args = BuildInvocation.swiftBuildArguments(mode: .strictCompleteV5, cachePath: GuestVM.swiftPMCache,
                                                       moduleCachePath: GuestVM.moduleCache)
        let s = MacCellRunner.script(arguments: args)
        #expect(s.contains("cd \(GuestVM.packageRoot)"))
        #expect(s.contains("xcodebuild -version"))
        #expect(s.contains(GuestVM.swiftPMCache) && s.contains(GuestVM.moduleCache))
        #expect(!s.contains("'/swiftpm-cache'") && !s.contains("'/modcache'"))
        #expect(s.hasSuffix("exit 0"))
    }

    @Test func linuxDefaultsAreUnchanged() {
        let args = BuildInvocation.swiftBuildArguments(mode: .strictCompleteV5)
        #expect(args.contains("/swiftpm-cache") && args.contains("/modcache"))
    }

    @Test func planFiltersByPlatform() {
        func pkg(_ id: String, _ p: [Platform]) -> CorpusPackage {
            CorpusPackage(id: id, url: "https://github.com/\(id)", sha: String(repeating: "a", count: 40),
                          stratum: .control, platforms: p, selection: "t")
        }
        let m = CorpusManifest(packages: [pkg("a/linux", [.linuxSPM]), pkg("b/mac", [.macosSPM]), pkg("c/both", [.linuxSPM, .macosSPM])])
        let mac = MatrixRun.plan(manifest: m, selection: MatrixSelection(platform: .macosSPM, toolchains: [Toolchain.macOSXcode]))
        #expect(mac.map(\.package.id) == ["b/mac", "c/both"])
        let linux = MatrixRun.plan(manifest: m, selection: MatrixSelection(platform: .linuxSPM, toolchains: [Toolchain.matrix[0]]))
        #expect(linux.map(\.package.id) == ["a/linux", "c/both"])
    }

    @Test func guestInstanceNamesAreLimaSafe() {
        #expect(GuestVM(runId: "2026-10-10_macOS rerun").instance == "census-run-2026-10-10-macos-rerun")
    }

    @Test func parsesMacVersionLines() {
        let env = "Apple Swift version 6.4\nTarget: arm64-apple-macosx27.0.0\nProductVersion:\t\t27.0.1\nBuildVersion:\t\t26A434\nXcode 27.0\nBuild version 27A266a\narm64"
        #expect(OutcomeClassifier.value(forPrefix: "BuildVersion:", inVersionOutput: env) == "26A434")
        #expect(OutcomeClassifier.value(forPrefix: "Build version", inVersionOutput: env) == "27A266a")
        #expect(OutcomeClassifier.value(forPrefix: "BuildVersion:", inVersionOutput: "Swift version 6.3") == nil)
    }
}

@Suite struct RunStoreWriteTests {
    /// cell.json is the completion marker, so a write must replace the file whole (temp file + rename) and leave no debris.
    @Test func overwritesInPlaceAndLeavesNoTempFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runstore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a/cell.json")
        let store = RunStore(root: dir)
        try store.write(["k": "first value that is long"], to: url)
        try store.write(["k": "2nd"], to: url)
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        #expect(decoded == ["k": "2nd"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["cell.json"])
    }
}
