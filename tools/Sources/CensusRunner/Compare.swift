import CensusCore
import Foundation

/// The A7 check, as restated by ADR 0010 rule 2: two runs on identical inputs have the same cells, equal outcomes
/// everywhere, and an equal normalised diagnostic multiset in every `built` cell. This compares two committed runs
/// cell by cell.
public enum RunComparison {
    public struct CellDifference: Sendable {
        public var key: RunStore.CellKey
        public var difference: NormalisedMultiset.Difference
    }

    public struct Report: Sendable {
        public var cellsCompared = 0
        public var identical = 0
        public var differing: [CellDifference] = []
        /// `build_failed` on both sides with differing multisets. Reported, never gating (ADR 0010 rule 2): a failed
        /// build's diagnostics are whatever had run when it stopped, which depends on parallel scheduling.
        public var failedBuildDiffering: [CellDifference] = []
        /// Cells that ended with a different outcome. Not comparable, and not silently ignored.
        public var outcomeMismatches: [(key: RunStore.CellKey, left: CellOutcome, right: CellOutcome)] = []
        public var onlyInLeft: [RunStore.CellKey] = []
        public var onlyInRight: [RunStore.CellKey] = []
        /// Cells with an outcome that carries no diagnostics on either side (timeouts, tools-version,
        /// infra); equal outcomes there are trivially identical and are counted separately.
        public var noDiagnosticCells = 0

        public var isSetIdentical: Bool {
            differing.isEmpty && outcomeMismatches.isEmpty && onlyInLeft.isEmpty && onlyInRight.isEmpty
        }
    }

    static func hasDiagnostics(_ o: CellOutcome) -> Bool { o == .built || o == .buildFailed }

    public static func compare(_ left: [RunStore.CellKey: RunStore.LoadedCell],
                               _ right: [RunStore.CellKey: RunStore.LoadedCell]) -> Report {
        var report = Report()
        report.onlyInLeft = left.keys.filter { right[$0] == nil }.sorted()
        report.onlyInRight = right.keys.filter { left[$0] == nil }.sorted()
        for key in left.keys.sorted() {
            guard let l = left[key], let r = right[key] else { continue }
            report.cellsCompared += 1
            guard l.record.outcome == r.record.outcome else {
                report.outcomeMismatches.append((key, l.record.outcome, r.record.outcome))
                continue
            }
            guard hasDiagnostics(l.record.outcome) else {
                report.noDiagnosticCells += 1
                continue
            }
            let diff = NormalisedMultiset(records: l.diagnostics).difference(NormalisedMultiset(records: r.diagnostics))
            if diff.isEmpty {
                report.identical += 1
            } else if l.record.outcome == .buildFailed {
                report.failedBuildDiffering.append(.init(key: key, difference: diff))
            } else {
                report.differing.append(.init(key: key, difference: diff))
            }
        }
        return report
    }
}
