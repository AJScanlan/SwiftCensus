import CensusCore
import Foundation
import Yams

public enum Eligibility: Equatable, Sendable {
    case eligible(sha: String, branch: String)
    case rejected(String)
}

public struct DrawSpec: Sendable {
    public var seed: UInt64
    public var count: Int
    /// First shuffle position considered: 0 for a fresh draw, one past the last drawn position for an extension (D5).
    public var startPosition: Int
    public var packageListSHA: String
    /// The draw date, `YYYY-MM-DD`, recorded in each entry's `selection`.
    public var date: String
    public var stratum: Stratum
    public var platforms: [Platform]

    public init(seed: UInt64, count: Int, startPosition: Int, packageListSHA: String, date: String,
                stratum: Stratum, platforms: [Platform]) {
        self.seed = seed
        self.count = count
        self.startPosition = startPosition
        self.packageListSHA = packageListSHA
        self.date = date
        self.stratum = stratum
        self.platforms = platforms
    }
}

public struct DrawResult: Sendable {
    public var packages: [CorpusPackage]
    public var rejected: [String: Int]
}

/// The seeded walk over the PackageList shared by `S-control` and the screen (ADR 0007). Pure apart from `check`,
/// which is the network half of eligibility, so the order, skipping and output are testable against fixtures.
public enum Draw {
    public static func repos(fromPackageList urls: [String]) -> [String: String] {
        var byId: [String: String] = [:]
        for u in urls { if let r = Selection.githubRepo(from: u) { byId["\(r.owner)/\(r.repo)"] = r.url } }
        return byId
    }

    public static func draw(
        repos: [String: String], spec: DrawSpec, excluding: Set<String>,
        check: (_ id: String, _ url: String) async throws -> Eligibility
    ) async rethrows -> DrawResult {
        var drawn: [CorpusPackage] = []
        var rejected: [String: Int] = [:]
        for (position, id) in Selection.seededShuffle(Array(repos.keys), seed: spec.seed).enumerated()
        where position >= spec.startPosition {
            if drawn.count >= spec.count { break }
            if excluding.contains(id) { rejected["already in corpus or candidates", default: 0] += 1; continue }
            guard let url = repos[id] else { continue }
            switch try await check(id, url) {
            case .rejected(let reason):
                rejected[reason, default: 0] += 1
            case .eligible(let sha, let branch):
                drawn.append(CorpusPackage(
                    id: id, url: url, sha: sha, stratum: spec.stratum, platforms: spec.platforms,
                    selection: "seed=\(spec.seed) draw-position=\(position) PackageList@\(spec.packageListSHA) "
                        + "HEAD of \(branch) on \(spec.date)"))
            }
        }
        return DrawResult(packages: drawn, rejected: rejected)
    }

    public enum MetadataCheck: Equatable, Sendable {
        case active(branch: String)
        case rejected(String)
    }

    /// The pre-registered eligibility rule (ADR 0004 §5, ADR 0007) over GitHub's
    /// `archived \t disabled \t pushed_at \t default_branch`. `nil` means the API call failed.
    public static func checkMetadata(_ tsv: String?, now: Date, activeDays: Int) -> MetadataCheck {
        let f = (tsv ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").map(String.init)
        guard tsv != nil, f.count == 4 else { return .rejected("unavailable (renamed/removed)") }
        if f[0] == "true" || f[1] == "true" { return .rejected("archived or disabled") }
        let cutoff = now.addingTimeInterval(-Double(activeDays) * 86400)
        guard let pushed = ISO8601DateFormatter().date(from: f[2]), pushed >= cutoff else {
            return .rejected("inactive > \(activeDays)d")
        }
        return .active(branch: f[3])
    }

    /// D5: an extension continues the *same* order. Every existing candidate must record this seed and PackageList
    /// commit in its `selection`; returns the first that does not, so a mismatched extension is refused.
    public static func extensionMismatch(_ existing: [CorpusPackage], seed: UInt64, packageListSHA: String) -> String? {
        existing.first {
            !$0.selection.contains("seed=\(seed) ") || !$0.selection.contains("PackageList@\(packageListSHA) ")
        }?.id
    }

    /// The `draw-position=` that `draw` recorded in a `selection` string. An extension resumes one past the largest.
    public static func position(inSelection s: String) -> Int? {
        guard let r = s.range(of: "draw-position=") else { return nil }
        return Int(s[r.upperBound...].prefix { $0.isNumber })
    }
}

public enum CorpusYAML {
    /// `sortKeys` orders each entry's keys deterministically (G9). Package order is the caller's: the corpus sorts,
    /// the screen keeps draw order.
    public static func encode(_ manifest: CorpusManifest, header: String) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        encoder.options.width = 120
        return header + (try encoder.encode(manifest))
    }
}
