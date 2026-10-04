import Foundation
import Testing

@testable import SuppressionScan

private func counts(_ source: String, path: String = "Sources/X/X.swift") -> SuppressionCounts {
    SuppressionScan.scan(source: source, path: path).counts
}

@Suite struct TaxonomyTests {
    @Test func uncheckedSendableInConformanceClause() {
        let c = counts("""
        final class A: @unchecked Sendable {}
        struct B: Equatable, @unchecked Sendable {}
        extension C: @unchecked Sendable {}
        final class D: @unchecked Swift.Sendable {}
        """)
        #expect(c.uncheckedSendable == 4)
    }

    @Test func uncheckedOnANonSendableProtocolIsNotCounted() {
        #expect(counts("final class A: @unchecked Foo {}").uncheckedSendable == 0)
    }

    @Test func nonisolatedUnsafeIsCountedButPlainNonisolatedIsNot() {
        let c = counts("""
        nonisolated(unsafe) var a = 0
        nonisolated(unsafe) static let b = 1
        nonisolated func f() {}
        nonisolated let g = 2
        """)
        #expect(c.nonisolatedUnsafe == 2)
    }

    /// The load-bearing split: an import is staging, a declaration is deliberate suppression.
    @Test func preconcurrencyImportAndDeclarationAreCountedSeparately() {
        let c = counts("""
        @preconcurrency import Foundation
        @preconcurrency import struct Dep.Thing
        @preconcurrency public protocol P {}
        struct S: @preconcurrency Equatable {}
        @preconcurrency @MainActor func f() {}
        """)
        #expect(c.preconcurrencyImport == 2)
        #expect(c.preconcurrencyDeclaration == 3)
    }

    @Test func assumeIsolatedCalls() {
        let c = counts("""
        func f(actor: A) {
            MainActor.assumeIsolated { }
            actor.assumeIsolated { _ in }
            self.assumeIsolated { }
        }
        """)
        #expect(c.assumeIsolated == 3)
    }

    @Test func unsafeFlagsCountedInManifestsOnly() {
        let source = """
        let p = Package(name: "X", targets: [
          .target(name: "A", swiftSettings: [.unsafeFlags(["-suppress-warnings"])]),
          .target(name: "B", swiftSettings: [SwiftSetting.unsafeFlags(["-x"])]),
        ])
        """
        #expect(counts(source, path: "Package.swift").unsafeFlags == 2)
        #expect(counts(source, path: "Package@swift-5.9.swift").unsafeFlags == 2)
        #expect(counts(source, path: "Sources/X/X.swift").unsafeFlags == 0)
    }
}

/// A regex census would be wrong in a direction that flatters the finding (A10): these
/// constructs routinely appear in comments, docs and string literals.
@Suite struct DecoyTests {
    @Test func commentsAndStringsAreNotCounted() {
        let c = counts(#"""
        // final class A: @unchecked Sendable {}
        /* nonisolated(unsafe) var x = 0 */
        /// Use `@preconcurrency import Foo` and `MainActor.assumeIsolated { }` here.
        let doc = "@unchecked Sendable nonisolated(unsafe) @preconcurrency import assumeIsolated()"
        let multi = """
        @preconcurrency import Foo
        final class B: @unchecked Sendable {}
        """
        """#)
        #expect(c.isEmpty)
    }

    @Test func realOccurrencesNextToDecoysAreStillCounted() {
        let c = counts("""
        // @unchecked Sendable in a comment
        final class A: @unchecked Sendable {} // and a real one
        """)
        #expect(c.uncheckedSendable == 1)
    }
}

@Suite struct LineAndConfidenceTests {
    @Test func nonCommentLinesExcludeBlankAndCommentOnlyLines() {
        let scan = SuppressionScan.scan(source: """
        // header

        /* block
           comment */
        let a = 1   // trailing comment
        let b = 2
        """, path: "a.swift")
        #expect(scan.nonCommentLines == 2)
    }

    @Test func multiLineStringLiteralLinesCount() {
        let scan = SuppressionScan.scan(source: "let s = \"\"\"\nline\nline\n\"\"\"\n", path: "a.swift")
        #expect(scan.nonCommentLines == 4)
    }

    @Test func cleanFileIsFlaggedClean() {
        #expect(SuppressionScan.scan(source: "struct A {}\n", path: "a.swift").parsedCleanly)
    }

    @Test func brokenFileIsFlaggedNotDropped() {
        let scan = SuppressionScan.scan(source: "struct A { func ( }\n@unchecked", path: "a.swift")
        #expect(!scan.parsedCleanly)
    }
}

@Suite struct PackageScanTests {
    func makePackage(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID())")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func scopeExcludesTestsBuildStateAndCheckouts() throws {
        let root = try makePackage([
            "Sources/A/A.swift": "final class A: @unchecked Sendable {}\n",
            "Tests/ATests/ATests.swift": "final class T: @unchecked Sendable {}\n",
            "Sources/Extra/FooTests/X.swift": "final class T: @unchecked Sendable {}\n",
            ".build/checkouts/dep/Sources/D/D.swift": "final class D: @unchecked Sendable {}\n",
            "Package.swift": "let p = Package(name: \"A\", targets: [.target(name: \"A\", swiftSettings: [.unsafeFlags([\"-x\"])])])\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let scan = try SuppressionScan.scanPackage(root: root)
        #expect(scan.files.map(\.path) == ["Package.swift", "Sources/A/A.swift"])
        #expect(scan.counts.uncheckedSendable == 1)
        #expect(scan.counts.unsafeFlags == 1)
        // Only Sources/A/A.swift is in the denominator; the manifest is not source.
        #expect(scan.nonCommentLines == 1)
        #expect(scan.cleanParseFraction == 1.0)
    }

    @Test func cleanParseFractionReflectsBrokenFiles() throws {
        let root = try makePackage([
            "Sources/A/ok.swift": "struct A {}\n",
            "Sources/A/bad.swift": "struct B { func ( }\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try SuppressionScan.scanPackage(root: root).cleanParseFraction == 0.5)
    }

    @Test func emptyPackageDoesNotDivideByZero() throws {
        let root = try makePackage(["README.md": "x"])
        defer { try? FileManager.default.removeItem(at: root) }
        let scan = try SuppressionScan.scanPackage(root: root)
        #expect(scan.files.isEmpty)
        #expect(scan.perThousandLines == 0)
    }
}
