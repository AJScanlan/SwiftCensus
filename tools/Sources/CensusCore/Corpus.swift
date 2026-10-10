import Foundation

/// A3 strata. Entry selection comes from measurement, never prestige (P1).
public enum Stratum: String, Codable, Sendable, CaseIterable {
    case emit = "S-emit"
    case control = "S-control"
    case anchor = "S-anchor"
    case byproduct = "S-byproduct"
    /// ADR 0007: a screen candidate, kept in `screens/<id>/candidates.yaml`. Not a corpus stratum: labelling
    /// non-members `S-emit` would survive into `census validate` as a lie.
    case screen
}

public enum Platform: String, Codable, Sendable {
    case linuxSPM = "linux-spm"
    case macosSPM = "macos-spm"
}

/// One pinned corpus entry (SPEC §5.1 plus A3's fields).
public struct CorpusPackage: Codable, Equatable, Sendable {
    public var id: String
    public var url: String
    /// 40-character commit SHA. "Latest" is forbidden (P7).
    public var sha: String
    public var stratum: Stratum
    public var platforms: [Platform]
    /// How this entry came to be in the sample, so the selection is auditable (P1).
    public var selection: String
    /// The count the selection signal reported at selection time. Nil where the stratum has no such signal.
    public var spiErrorCountAtSelection: Int?
    /// ADR 0007: the screen this entry was selected from, and its `screen_count` then. Separate from the SPI field
    /// on purpose: the two signals measure different things and must never be mixed.
    public var screenId: String?
    public var screenCountAtSelection: Int?
    public var skipReason: String?

    enum CodingKeys: String, CodingKey {
        case id, url, sha, stratum, platforms, selection
        case spiErrorCountAtSelection = "spi_error_count_at_selection"
        case screenId = "screen_id"
        case screenCountAtSelection = "screen_count_at_selection"
        case skipReason = "skip_reason"
    }

    public init(id: String, url: String, sha: String, stratum: Stratum, platforms: [Platform],
                selection: String, spiErrorCountAtSelection: Int? = nil, screenId: String? = nil,
                screenCountAtSelection: Int? = nil, skipReason: String? = nil) {
        self.id = id
        self.url = url
        self.sha = sha
        self.stratum = stratum
        self.platforms = platforms
        self.selection = selection
        self.spiErrorCountAtSelection = spiErrorCountAtSelection
        self.screenId = screenId
        self.screenCountAtSelection = screenCountAtSelection
        self.skipReason = skipReason
    }

    /// Filesystem-safe form of the id, used for run directories and vendored resolved files.
    public var slug: String { id.replacingOccurrences(of: "/", with: "__") }
}

public struct CorpusManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var packages: [CorpusPackage]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case packages
    }

    public init(schemaVersion: Int = 1, packages: [CorpusPackage]) {
        self.schemaVersion = schemaVersion
        self.packages = packages
    }

    public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
        public var packageId: String
        public var message: String
        public var description: String { "\(packageId): \(message)" }
    }

    /// P7: every entry must be pinned to a full commit SHA, ids must be unique, and urls must be
    /// https. Returns all issues rather than the first so one run reports the whole manifest.
    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var seen = Set<String>()
        for p in packages {
            if !seen.insert(p.id).inserted { issues.append(.init(packageId: p.id, message: "duplicate id")) }
            if !Self.isFullSHA(p.sha) {
                issues.append(.init(packageId: p.id, message: "sha must be a 40-character lowercase hex commit (got '\(p.sha)')"))
            }
            if !p.url.hasPrefix("https://") {
                issues.append(.init(packageId: p.id, message: "url must be https (got '\(p.url)')"))
            }
            if p.platforms.isEmpty && p.skipReason == nil {
                issues.append(.init(packageId: p.id, message: "no platforms and no skip_reason"))
            }
        }
        return issues
    }

    public static func isFullSHA(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
