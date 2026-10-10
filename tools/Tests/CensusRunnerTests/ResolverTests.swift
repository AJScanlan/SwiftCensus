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
        let pending = Resolver.pending(all, resolvedDirectory: dir, provenance: provenance, failures: [:], force: false)
        #expect(pending.map(\.id) == ["o/fileonly", "o/provonly", "o/new"])
        #expect(Resolver.pending(all, resolvedDirectory: dir, provenance: provenance, failures: [:], force: true).count == 4)
    }

    /// An operator-recorded unresolvable (a persistent fetch failure) is a decision, not a transient failure: it is
    /// never retried. A tool-recorded failure stays pending so the driver's second attempt retries it. `--force`
    /// still re-resolves everything.
    @Test func operatorRecordedFailuresAreNotRetried() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let all = [pkg("o/op"), pkg("o/tool"), pkg("o/new")]
        let failures = ["o/op": "operator: private submodule", "o/tool": "o/tool: dependency resolution failed:\nx"]
        let pending = Resolver.pending(all, resolvedDirectory: dir, provenance: [:], failures: failures, force: false)
        #expect(pending.map(\.id) == ["o/tool", "o/new"])
        #expect(Resolver.pending(all, resolvedDirectory: dir, provenance: [:], failures: failures, force: true).count == 3)
    }
}

@Suite struct ResolverFailureClassificationTests {
    struct Boom: Error {}

    /// Only a genuine SwiftPM resolution failure is a property of the package. Everything else (docker, timeouts,
    /// source fetch) is infrastructure and must never reach failures.json, where it would read as `unresolvable`.
    @Test func onlyResolutionFailedIsAPackageFailure() {
        #expect(Resolver.isPackageFailure(ResolverError.resolutionFailed("o/p", "tail")))
        #expect(!Resolver.isPackageFailure(Boom()))
        #expect(!Resolver.isPackageFailure(CancellationError()))
        #expect(!Resolver.isPackageFailure(CocoaError(.fileWriteUnknown)))
    }
}

@Suite struct ResolverOutcomeMarkerTests {
    /// The container writes `/out/source` last-but-one. A marker that is `failed` is a SwiftPM verdict on the package;
    /// a marker that is missing means the container never got that far (ENOSPC, killed), which is infrastructure.
    @Test func failedMarkerIsAPackageFailure() {
        #expect(throws: ResolverError.self) { try Resolver.parseOutcome(marker: "failed\n", id: "o/p", log: "boom") }
        do { _ = try Resolver.parseOutcome(marker: "failed", id: "o/p", log: "boom") } catch {
            #expect(Resolver.isPackageFailure(error))
        }
    }

    @Test func missingOrEmptyMarkerIsNotAPackageFailure() {
        for marker in [nil, "", "  \n"] as [String?] {
            do {
                _ = try Resolver.parseOutcome(marker: marker, id: "o/p", log: "")
                Issue.record("expected a throw for marker \(String(describing: marker))")
            } catch {
                #expect(!Resolver.isPackageFailure(error))
                if case ResolverError.noOutcomeMarker = error {} else { Issue.record("wrong error \(error)") }
            }
        }
    }

    @Test func upstreamAndGeneratedAreSuccess() throws {
        #expect(try Resolver.parseOutcome(marker: "upstream\n", id: "o/p", log: "") == "upstream")
        #expect(try Resolver.parseOutcome(marker: "generated", id: "o/p", log: "") == "generated")
    }
}
