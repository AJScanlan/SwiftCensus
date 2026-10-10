import CensusCore
import Foundation
import Testing

@testable import CensusRunner

@Suite struct ResolverPendingTests {
    func pkg(_ id: String) -> CorpusPackage {
        CorpusPackage(id: id, url: "https://github.com/\(id)", sha: String(repeating: "a", count: 40),
                      stratum: .screen, platforms: [.macosSPM], selection: "t")
    }
    let prov = ResolvedProvenance(source: "upstream", toolchain: "6.4", resolvedAt: "x", sha256: "y", pinCount: 0)

    /// G3: a package is done only when both its file and its provenance entry exist; anything else is retried.
    @Test func skipsOnlyFullyVendoredPackagesUnlessForced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("o__done.resolved"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("o__fileonly.resolved"))
        let all = [pkg("o/done"), pkg("o/fileonly"), pkg("o/provonly"), pkg("o/new")]
        let provenance = ["o/done": prov, "o/provonly": prov]
        let pending = Resolver.pending(all, resolvedDirectory: dir, provenance: provenance, force: false)
        #expect(pending.map(\.id) == ["o/fileonly", "o/provonly", "o/new"])
        #expect(Resolver.pending(all, resolvedDirectory: dir, provenance: provenance, force: true).count == 4)
    }
}
