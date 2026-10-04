import Foundation

public enum Severity: String, Codable, Sendable, CaseIterable {
    case ignored, note, warning, error, fatal, remark
}

/// Where a diagnostic's source file lives relative to the package being measured (ROADMAP F2).
public enum Attribution: String, Codable, Sendable {
    /// Under the package's own source root. The only class that feeds the primary distribution.
    case primary
    /// Under `.build/checkouts/`: a dependency's source, never merged into the primary distribution.
    case transitive
    /// Under `.build/` but not a checkout: plugin output, derived sources, resource accessors.
    case generated
    /// Anywhere else: SDK, toolchain, a path dependency outside the root, or no location at all.
    case external
}

/// One parsed, deduplicated diagnostic. `parent` links a note to its parent diagnostic by index
/// into the same array (ROADMAP A8); the link is reconstructed from emission order.
public struct DiagnosticRecord: Codable, Hashable, Sendable {
    /// Compiler-internal identifier from `-debug-diagnostic-names` (A1). Nil only if the
    /// compiler printed none, in which case `text` is the fallback key.
    public var id: String?
    /// Rendered message with the identifier and group suffixes stripped.
    public var text: String
    public var severity: Severity
    /// `-print-diagnostic-groups` category, as a structured field from the `.dia`.
    public var group: String?
    public var groupURL: String?
    /// Package-relative for `primary`/`transitive`/`generated`; as emitted for `external`.
    public var path: String
    public var line: Int
    public var col: Int
    public var fixIts: Int
    public var attribution: Attribution
    public var parent: Int?

    public init(
        id: String?, text: String, severity: Severity, group: String?, groupURL: String?,
        path: String, line: Int, col: Int, fixIts: Int, attribution: Attribution, parent: Int?
    ) {
        self.id = id
        self.text = text
        self.severity = severity
        self.group = group
        self.groupURL = groupURL
        self.path = path
        self.line = line
        self.col = col
        self.fixIts = fixIts
        self.attribution = attribution
        self.parent = parent
    }

    public var key: DiagnosticKey {
        DiagnosticKey(id: id ?? "text:\(text)", path: path, line: line, col: col, severity: severity)
    }
}

/// The dedup key from CLAUDE.md, and the element of the A7 comparison multiset.
public struct DiagnosticKey: Codable, Hashable, Sendable, Comparable {
    public var id: String
    public var path: String
    public var line: Int
    public var col: Int
    public var severity: Severity

    public init(id: String, path: String, line: Int, col: Int, severity: Severity) {
        self.id = id
        self.path = path
        self.line = line
        self.col = col
        self.severity = severity
    }

    public static func < (a: Self, b: Self) -> Bool {
        (a.id, a.path, a.line, a.col, a.severity.rawValue)
            < (b.id, b.path, b.line, b.col, b.severity.rawValue)
    }
}
