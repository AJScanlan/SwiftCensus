import CensusCore
import Foundation
import Testing

@testable import DiagParse

/// The package root the fixtures were compiled under (see Fixtures/README.md).
private let fixtureRoot = "/private/tmp/probe/pkg"

private func fixtureURL(_ name: String) -> Foundation.URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
}

private func encode(_ records: [DiagnosticRecord]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(records)
}

@Suite struct GoldenTests {
    let tree = fixtureURL("probe-tree")

    @Test func parsesFixtureTreeToGolden() throws {
        let files = DiagParse.enumerateDia(under: tree)
        #expect(files.count == 3)
        let result = DiagParse.parse(diaFiles: files, packageRoot: fixtureRoot)
        #expect(result.unreadable.isEmpty)

        let actual = try encode(result.records)
        let goldenURL = fixtureURL("probe-tree.golden.json")
        if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] != nil {
            try actual.write(to: URL(fileURLWithPath: "/tmp/probe-tree.golden.json"))
        }
        let golden = try Data(contentsOf: goldenURL)
        #expect(actual == golden)
    }
}

@Suite struct ParserBehaviourTests {
    let tree = fixtureURL("probe-tree")

    @Test func duplicateDiaFilesCollapseToOneRecordPerDiagnostic() {
        let files = DiagParse.enumerateDia(under: tree)
        let one = DiagParse.parse(diaFiles: files.filter { $0.lastPathComponent == "Probe.dia" }, packageRoot: fixtureRoot)
        let two = DiagParse.parse(diaFiles: files.filter { $0.lastPathComponent.hasPrefix("Probe") }, packageRoot: fixtureRoot)
        #expect(one.records == two.records)
        #expect(two.diaFilesFound == 2)
    }

    @Test func notesAreLinkedToTheirParentAndNeverCountAsPrimaryErrors() throws {
        let result = DiagParse.parse(diaFiles: DiagParse.enumerateDia(under: tree), packageRoot: fixtureRoot)
        let primary = result.records.filter { $0.attribution == .primary }
        #expect(primary.filter { $0.severity == .error }.count == 2)
        let notes = primary.filter { $0.severity == .note }
        #expect(notes.count == 4)
        for note in notes {
            let parent = result.records[try #require(note.parent)]
            #expect(parent.severity == .error)
            #expect(parent.path == note.path)
        }
    }

    @Test func dependencyDiagnosticsAreNotPrimary() {
        let result = DiagParse.parse(diaFiles: DiagParse.enumerateDia(under: tree), packageRoot: fixtureRoot)
        let transitive = result.records.filter { $0.attribution == .transitive }
        #expect(transitive.count == 3)
        #expect(transitive.allSatisfy { $0.path.hasPrefix(".build/checkouts/Dep/") })
        #expect(NormalisedMultiset(records: result.records).keys.allSatisfy { $0.path.hasPrefix("Sources/") })
    }

    /// TSC traps on inputs of 4 bytes or fewer instead of throwing; one empty file must not
    /// take down a whole run.
    @Test(arguments: [0, 4, 5, 100])
    func unreadableFilesAreReportedNotDropped(truncatedTo length: Int) throws {
        let source = try Data(contentsOf: tree.appendingPathComponent("Probe.dia"))
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).dia")
        try source.prefix(length).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        let result = DiagParse.parse(diaFiles: [bad], packageRoot: fixtureRoot)
        #expect(result.records.isEmpty)
        #expect(result.unreadable.count == 1)
        #expect(result.diaFilesFound == 1)
    }
}

@Suite struct MessageSuffixTests {
    @Test(arguments: [
        ("boom [some_id] [#SomeGroup]", "boom", "some_id", "SomeGroup"),
        ("boom [some_id]", "boom", "some_id", nil),
        ("boom [#SomeGroup] [some_id]", "boom", "some_id", "SomeGroup"),
        ("boom", "boom", nil, nil),
        ("use of [Array] type [x_1]", "use of [Array] type", "x_1", nil),
        ("array index [Int] out", "array index [Int] out", nil, nil),
        ("trailing bracket [NotSnake]", "trailing bracket [NotSnake]", nil, nil),
    ] as [(String, String, String?, String?)])
    func splitsSuffixes(input: String, message: String, id: String?, group: String?) {
        let r = MessageSuffix.split(input)
        #expect(r.message == message)
        #expect(r.id == id)
        #expect(r.group == group)
    }
}
