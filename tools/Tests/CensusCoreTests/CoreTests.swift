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
