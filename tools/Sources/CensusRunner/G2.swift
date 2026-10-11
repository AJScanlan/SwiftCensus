import CensusCore
import Foundation

/// ROADMAP G2 as redefined by ADR 0007 D8, scored by the rules ADR 0008 pre-registers: of the 30 `S-emit` entries, how
/// many emit on Linux 6.4. Pure: it scores cells `RunStore` has already loaded.
public enum G2 {
    /// ADR 0008. Pre-registered: changing one is a new ADR, never an edit.
    public static let populationSize = 30
    public static let gatingToolchain = "6.4"
    public static let threshold = 0.5

    public enum Tertile: String, Codable, Sendable, CaseIterable { case head, middle, tail }

    public enum Verdict: String, Codable, Sendable {
        case pass, fail
        case notEvaluable = "not_evaluable"
    }

    public struct PackageResult: Codable, Equatable, Sendable {
        public var packageId: String
        public var tertile: Tertile?
        /// Nil when the run has no cell for this package on this column.
        public var outcome: CellOutcome?
        public var primaryNonNoteCount: Int
        public var emits: Bool

        enum CodingKeys: String, CodingKey {
            case packageId = "package_id", tertile, outcome
            case primaryNonNoteCount = "primary_non_note_count", emits
        }
    }

    public struct TertileCount: Codable, Equatable, Sendable {
        public var emits = 0
        public var total = 0
    }

    public struct Column: Codable, Equatable, Sendable {
        public var toolchain: String
        public var emits = 0
        /// Non-gating: ≥1 primary non-note diagnostic whatever the outcome, so a `build_failed` cell's errors count.
        public var emitsAnyOutcome = 0
        public var missing = 0
        public var infraError = 0
        public var byTertile: [String: TertileCount] = [:]
        public var packages: [PackageResult] = []

        enum CodingKeys: String, CodingKey {
            case toolchain, emits, emitsAnyOutcome = "emits_any_outcome", missing, infraError = "infra_error"
            case byTertile = "by_tertile", packages
        }
    }

    public struct Report: Codable, Equatable, Sendable {
        public var verdict: Verdict
        /// Why the verdict is `not_evaluable`; empty otherwise.
        public var reasons: [String]
        public var gatingToolchain: String
        public var threshold: Double
        public var population: Int
        public var columns: [Column]

        enum CodingKeys: String, CodingKey {
            case verdict, reasons, gatingToolchain = "gating_toolchain", threshold, population, columns
        }

        public var gating: Column? { columns.first { $0.toolchain == gatingToolchain } }
    }

    /// ADR 0007 D1's record filter: primary attribution, any severity but note.
    public static func primaryNonNoteCount(_ diagnostics: [DiagnosticRecord]) -> Int {
        diagnostics.filter { $0.attribution == .primary && $0.severity != .note }.count
    }

    /// ADR 0008: only a `built` cell emits. A Linux `build_failed` cell's primary errors are mostly missing Apple modules,
    /// which strict checking did not cause.
    public static func emits(_ cell: RunStore.LoadedCell) -> Bool {
        cell.record.outcome == .built && primaryNonNoteCount(cell.diagnostics) > 0
    }

    /// Read from the entry's `selection`, which `select emit --from-screen` writes as "… head-tertile of 47 …".
    public static func tertile(of package: CorpusPackage) -> Tertile? {
        Tertile.allCases.first { package.selection.contains("\($0.rawValue)-tertile") }
    }

    public static func evaluate(manifest: CorpusManifest,
                                cells: [RunStore.CellKey: RunStore.LoadedCell]) -> Report {
        let population = manifest.packages.filter { $0.stratum == .emit }.sorted { $0.id < $1.id }
        let ids = Set(population.map(\.id))
        let scored = cells.filter { ids.contains($0.key.packageId) && $0.key.mode == .strictCompleteV5 }

        var reasons: [String] = []
        if population.count != populationSize {
            reasons.append("the manifest has \(population.count) S-emit entries; ADR 0008 fixes \(populationSize)")
        }
        let untagged = population.filter { tertile(of: $0) == nil }.map(\.id)
        if !untagged.isEmpty { reasons.append("no tertile in selection: \(untagged.joined(separator: ", "))") }
        let foreign = scored.values.filter { $0.record.platform != .linuxSPM }.count
        if foreign > 0 { reasons.append("\(foreign) S-emit cells are not linux-spm; G2 is scored on Linux only") }

        let toolchains = Set(scored.keys.map(\.toolchain)).union([gatingToolchain]).sorted()
        let columns = toolchains.map { column($0, population: population, cells: scored) }
        let gating = columns.first { $0.toolchain == gatingToolchain } ?? Column(toolchain: gatingToolchain)
        if gating.missing > 0 { reasons.append("\(gating.missing) S-emit cells missing on \(gatingToolchain)") }
        if gating.infraError > 0 { reasons.append("\(gating.infraError) S-emit cells are infra_error on \(gatingToolchain)") }

        let verdict: Verdict = !reasons.isEmpty ? .notEvaluable
            : Double(gating.emits) / Double(populationSize) < threshold ? .fail : .pass
        return Report(verdict: verdict, reasons: reasons, gatingToolchain: gatingToolchain, threshold: threshold,
                      population: population.count, columns: columns)
    }

    static func column(_ toolchain: String, population: [CorpusPackage],
                       cells: [RunStore.CellKey: RunStore.LoadedCell]) -> Column {
        var c = Column(toolchain: toolchain)
        for p in population {
            let cell = cells[RunStore.CellKey(toolchain: toolchain, mode: .strictCompleteV5, packageId: p.id)]
            let outcome = cell?.record.outcome
            let count = cell.map { primaryNonNoteCount($0.diagnostics) } ?? 0
            let emitting = cell.map { emits($0) } ?? false
            let t = tertile(of: p)
            if outcome == nil { c.missing += 1 }
            if outcome == .infraError { c.infraError += 1 }
            if emitting { c.emits += 1 }
            if count > 0, outcome != .infraError { c.emitsAnyOutcome += 1 }
            if let t {
                c.byTertile[t.rawValue, default: TertileCount()].total += 1
                if emitting { c.byTertile[t.rawValue, default: TertileCount()].emits += 1 }
            }
            c.packages.append(PackageResult(packageId: p.id, tertile: t, outcome: outcome,
                                            primaryNonNoteCount: count, emits: emitting))
        }
        return c
    }
}
