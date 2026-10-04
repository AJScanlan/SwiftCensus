import Foundation

/// The A10 taxonomy. Counted separately and never merged into one "escape hatch" number:
/// the constructs mean materially different things, and lumping `@preconcurrency import`
/// (usually good practice) with the rest would inflate the headline with the weakest signal.
public struct SuppressionCounts: Codable, Equatable, Sendable {
    /// `@unchecked Sendable` in an inheritance clause.
    public var uncheckedSendable = 0
    /// `nonisolated(unsafe)` declaration modifier.
    public var nonisolatedUnsafe = 0
    /// `@preconcurrency import` — staging a not-yet-audited dependency; the weakest signal.
    public var preconcurrencyImport = 0
    /// `@preconcurrency` on a declaration or in a conformance clause — narrower, deliberate.
    public var preconcurrencyDeclaration = 0
    /// `assumeIsolated(...)` calls, including `MainActor.assumeIsolated`.
    public var assumeIsolated = 0
    /// `.unsafeFlags([...])`, counted in package manifests only.
    public var unsafeFlags = 0

    public init() {}

    public static func += (l: inout Self, r: Self) {
        l.uncheckedSendable += r.uncheckedSendable
        l.nonisolatedUnsafe += r.nonisolatedUnsafe
        l.preconcurrencyImport += r.preconcurrencyImport
        l.preconcurrencyDeclaration += r.preconcurrencyDeclaration
        l.assumeIsolated += r.assumeIsolated
        l.unsafeFlags += r.unsafeFlags
    }

    public var isEmpty: Bool { self == SuppressionCounts() }
}

public struct FileScan: Codable, Equatable, Sendable {
    public var path: String
    public var isManifest: Bool
    public var counts: SuppressionCounts
    /// Lines carrying at least one token that is not trivia — the "non-comment source lines" denominator.
    public var nonCommentLines: Int
    /// False when swift-syntax reported a syntax error. SwiftSyntax does not crash on syntax newer
    /// than its pinned version but can misparse it, so counts from an unclean file are suspect (A10).
    public var parsedCleanly: Bool
}

public struct PackageScan: Codable, Equatable, Sendable {
    public var scope: String
    public var files: [FileScan]
    public var counts: SuppressionCounts
    public var nonCommentLines: Int
    /// Fraction of scanned files that parsed without error; the report states this (A10).
    public var cleanParseFraction: Double
    /// Occurrences of everything except `.unsafeFlags` per 1,000 non-comment source lines.
    public var perThousandLines: Double
}
