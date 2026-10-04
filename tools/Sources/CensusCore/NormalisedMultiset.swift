import Foundation

/// The A7 comparison object: the sorted multiset of
/// `(diagnostic_id, repo_relative_path, line, col, severity)` over primary-attributed records.
public struct NormalisedMultiset: Codable, Equatable, Sendable {
    public let keys: [DiagnosticKey]

    public init(records: [DiagnosticRecord]) {
        keys = records.filter { $0.attribution == .primary }.map(\.key).sorted()
    }

    public struct Difference: Equatable, Sendable {
        public var onlyInLeft: [DiagnosticKey]
        public var onlyInRight: [DiagnosticKey]
        public var isEmpty: Bool { onlyInLeft.isEmpty && onlyInRight.isEmpty }
    }

    /// Multiset difference: a key present twice on one side and once on the other shows up once.
    public func difference(_ other: NormalisedMultiset) -> Difference {
        func counts(_ ks: [DiagnosticKey]) -> [DiagnosticKey: Int] {
            ks.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        let l = counts(keys), r = counts(other.keys)
        var left: [DiagnosticKey] = [], right: [DiagnosticKey] = []
        for k in Set(l.keys).union(r.keys) {
            let d = l[k, default: 0] - r[k, default: 0]
            if d > 0 { left += Array(repeating: k, count: d) }
            if d < 0 { right += Array(repeating: k, count: -d) }
        }
        return Difference(onlyInLeft: left.sorted(), onlyInRight: right.sorted())
    }
}
