import CensusCore
import Foundation

/// SplitMix64: a tiny, fully specified PRNG. The standard library's `shuffled(using:)` is allowed
/// to change its algorithm between Swift releases, which would make a "seeded" corpus draw
/// irreproducible across toolchains — and the corpus is pinned deliberately (P7).
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct SPIRow: Equatable, Sendable {
    public var url: String
    public var errors: Int
    public var swiftVersion: String
    public var asOf: String
}

public enum SelectionError: Error, CustomStringConvertible {
    case badCSV(String)
    public var description: String {
        switch self { case .badCSV(let m): "spi data: \(m)" }
    }
}

public enum Selection {
    /// Canonicalises a PackageList URL to `(owner, repo, https URL)`. Non-GitHub hosts return nil:
    /// the source cache and the GitHub eligibility check both assume github.com.
    public static func githubRepo(from raw: String) -> (owner: String, repo: String, url: String)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        guard let comps = URLComponents(string: s), comps.host?.lowercased() == "github.com" else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1], "https://github.com/\(parts[0])/\(parts[1])")
    }

    /// Deterministic Fisher–Yates over a canonically ordered input: the same list and seed give the
    /// same order on every toolchain and platform.
    public static func seededShuffle<T: Comparable>(_ items: [T], seed: UInt64) -> [T] {
        var out = items.sorted()
        var rng = SplitMix64(seed: seed)
        guard out.count > 1 else { return out }
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            out.swapAt(i, j)
        }
        return out
    }

    /// Expected columns, in order: `package_url,data_race_errors,swift_version,as_of`.
    public static func parseSPICSV(_ text: String) throws -> [SPIRow] {
        var rows: [SPIRow] = []
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        guard let header = lines.first else { throw SelectionError.badCSV("empty file") }
        let expected = "package_url,data_race_errors,swift_version,as_of"
        guard header.replacingOccurrences(of: " ", with: "") == expected else {
            throw SelectionError.badCSV("header must be '\(expected)', got '\(header)'")
        }
        for (i, line) in lines.dropFirst().enumerated() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count == 4, let n = Int(f[1]), n >= 0 else { throw SelectionError.badCSV("row \(i + 2): '\(line)'") }
            rows.append(SPIRow(url: f[0], errors: n, swiftVersion: f[2], asOf: f[3]))
        }
        return rows
    }

    public enum Tertile: String, Sendable { case head, middle, tail }

    /// A3: `S-emit` is "sampled across the count distribution (head / middle / long tail)". Rows with
    /// errors > 0 are ordered by count and cut into three contiguous groups of near-equal size, and
    /// each group contributes an equal share of the sample. Sampling the raw distribution instead
    /// would hand almost every slot to the many packages with one or two errors.
    public static func sampleAcrossDistribution(
        rows: [SPIRow], count: Int, seed: UInt64
    ) -> [(row: SPIRow, tertile: Tertile)] {
        let emitting = rows.filter { $0.errors > 0 }.sorted { ($1.errors, $0.url) < ($0.errors, $1.url) }
        guard !emitting.isEmpty else { return [] }
        let size = emitting.count
        let cuts = [0, size / 3 + (size % 3 > 0 ? 1 : 0), size / 3 * 2 + min(size % 3, 2), size]
        let tertiles: [Tertile] = [.head, .middle, .tail]
        var out: [(SPIRow, Tertile)] = []
        for g in 0..<3 {
            let group = Array(emitting[cuts[g]..<cuts[g + 1]])
            let share = count / 3 + (g < count % 3 ? 1 : 0)
            var rng = SplitMix64(seed: seed &+ UInt64(g))
            var shuffled = group
            if shuffled.count > 1 {
                for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
                    shuffled.swapAt(i, Int(rng.next() % UInt64(i + 1)))
                }
            }
            out += shuffled.prefix(share).map { ($0, tertiles[g]) }
        }
        return out
    }
}
