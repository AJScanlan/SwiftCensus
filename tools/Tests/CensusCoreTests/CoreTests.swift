import Foundation
import Testing

@testable import CensusCore

@Suite struct PathAttributionTests {
    let root = "/pkg"

    @Test(arguments: [
        ("/pkg/Sources/A/a.swift", Attribution.primary, "Sources/A/a.swift"),
        ("/pkg/.build/checkouts/dep/Sources/D/d.swift", .transitive, ".build/checkouts/dep/Sources/D/d.swift"),
        ("/pkg/.build/x86_64-unknown-linux-gnu/debug/A.build/resource_bundle_accessor.swift", .generated,
         ".build/x86_64-unknown-linux-gnu/debug/A.build/resource_bundle_accessor.swift"),
        ("/usr/lib/swift/Foundation.swiftinterface", .external, "/usr/lib/swift/Foundation.swiftinterface"),
        ("/pkg-other/Sources/a.swift", .external, "/pkg-other/Sources/a.swift"),
        ("/pkg", .external, "/pkg"),
    ] as [(String, Attribution, String)])
    func classifies(path: String, expected: Attribution, relative: String) {
        let r = PathAttribution.classify(path: path, root: root)
        #expect(r.attribution == expected)
        #expect(r.path == relative)
    }

    @Test func trailingSlashOnRootIsTolerated() {
        #expect(PathAttribution.classify(path: "/pkg/Sources/a.swift", root: "/pkg/").attribution == .primary)
    }
}

@Suite struct NormalisedMultisetTests {
    func rec(_ id: String, _ path: String, _ line: Int, attribution: Attribution = .primary,
             severity: Severity = .error) -> DiagnosticRecord {
        DiagnosticRecord(id: id, text: "t", severity: severity, group: nil, groupURL: nil, path: path,
                         line: line, col: 1, fixIts: 0, attribution: attribution, parent: nil)
    }

    @Test func isOrderIndependent() {
        let a = [rec("x", "a.swift", 1), rec("y", "b.swift", 2)]
        #expect(NormalisedMultiset(records: a) == NormalisedMultiset(records: a.reversed()))
    }

    @Test func excludesNonPrimary() {
        let m = NormalisedMultiset(records: [rec("x", "a.swift", 1), rec("x", "d.swift", 1, attribution: .transitive)])
        #expect(m.keys.count == 1)
    }

    @Test func isAMultisetNotASet() {
        let one = NormalisedMultiset(records: [rec("x", "a.swift", 1)])
        let two = NormalisedMultiset(records: [rec("x", "a.swift", 1), rec("x", "a.swift", 1)])
        #expect(one != two)
        let d = two.difference(one)
        #expect(d.onlyInLeft.count == 1 && d.onlyInRight.isEmpty)
    }

    @Test func severityIsPartOfTheKey() {
        let e = NormalisedMultiset(records: [rec("x", "a.swift", 1, severity: .error)])
        let w = NormalisedMultiset(records: [rec("x", "a.swift", 1, severity: .warning)])
        #expect(!e.difference(w).isEmpty)
    }
}

@Suite struct CorpusManifestTests {
    func pkg(_ id: String = "a/a", sha: String = String(repeating: "a", count: 40), url: String = "https://github.com/a/a",
             platforms: [Platform] = [.linuxSPM], skip: String? = nil) -> CorpusPackage {
        CorpusPackage(id: id, url: url, sha: sha, stratum: .emit, platforms: platforms, selection: "t", skipReason: skip)
    }

    @Test func pinnedManifestIsValid() {
        #expect(CorpusManifest(packages: [pkg()]).validate().isEmpty)
    }

    /// P7: "latest", branch names, tags and abbreviated SHAs are all forbidden.
    @Test(arguments: ["latest", "main", "6.1.0", "abc1234", String(repeating: "A", count: 40), String(repeating: "g", count: 40)])
    func nonSHAPinsAreRejected(sha: String) {
        #expect(!CorpusManifest(packages: [pkg(sha: sha)]).validate().isEmpty)
    }

    @Test func duplicateIdsHttpAndEmptyPlatformsAreReported() {
        let m = CorpusManifest(packages: [pkg(), pkg(), pkg("b/b", url: "http://x"), pkg("c/c", platforms: [])])
        #expect(m.validate().count == 3)
        #expect(CorpusManifest(packages: [pkg(platforms: [], skip: "needs Apple SDK")]).validate().isEmpty)
    }

    @Test func slugIsFilesystemSafe() {
        #expect(pkg("pointfreeco/swift-dependencies").slug == "pointfreeco__swift-dependencies")
    }
}

@Suite struct DiagnosticTallyTests {
    @Test func tallySeparatesNotesFromDiagnosticsAndNonPrimary() {
        func r(_ a: Attribution, _ s: Severity) -> DiagnosticRecord {
            DiagnosticRecord(id: "x", text: "", severity: s, group: nil, groupURL: nil, path: "p", line: 1, col: 1,
                             fixIts: 0, attribution: a, parent: nil)
        }
        let t = DiagnosticTally(records: [r(.primary, .error), r(.primary, .warning), r(.primary, .note), r(.primary, .note),
                                          r(.transitive, .error), r(.external, .warning)])
        #expect(t.primaryErrors == 1 && t.primaryWarnings == 1 && t.primaryNotes == 2)
        #expect(t.transitive == 1 && t.external == 1)
    }
}

@Suite struct CorpusPackageCodingTests {
    let sha = String(repeating: "a", count: 40)

    @Test func entriesWrittenBeforeTheScreenStillDecode() throws {
        let json = #"{"id":"a/a","url":"https://github.com/a/a","sha":"\#(sha)","stratum":"S-control","platforms":["linux-spm"],"selection":"t","spi_error_count_at_selection":3}"#
        let p = try JSONDecoder().decode(CorpusPackage.self, from: Data(json.utf8))
        #expect(p.screenId == nil && p.screenCountAtSelection == nil && p.spiErrorCountAtSelection == 3)
    }

    /// The screen count has its own field: `spi_error_count_at_selection` is never reused for it (ADR 0007).
    @Test func screenFieldsRoundTripUnderSnakeCaseKeys() throws {
        let p = CorpusPackage(id: "a/a", url: "https://github.com/a/a", sha: sha, stratum: .emit, platforms: [.linuxSPM, .macosSPM],
                              selection: "t", screenId: "screen-2026-10-10", screenCountAtSelection: 7)
        let data = try JSONEncoder().encode(p)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"screen_id\"") && text.contains("\"screen_count_at_selection\""))
        #expect(!text.contains("spi_error_count_at_selection"))
        #expect(try JSONDecoder().decode(CorpusPackage.self, from: data) == p)
    }

    @Test func screenIsAStratum() {
        #expect(Stratum(rawValue: "screen") == .screen)
    }
}
