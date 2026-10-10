import CensusCore
import Foundation

/// ADR 0007 §5.4. Every drawn candidate ends in exactly one of these, and the denominator table sums them.
public enum ScreenStatus: String, Codable, Sendable, CaseIterable {
    case emitter
    case clean
    case notScreenable = "not_screenable"
    case minimalFailed = "minimal_failed"
    case unresolvable
    case infraError = "infra_error"
    case unstable
}

public struct ScreenResult: Codable, Equatable, Sendable {
    public var packageId: String
    public var sha: String
    public var status: ScreenStatus
    public var reason: String?
    /// Nil only for `unresolvable`: no cell was built.
    public var completeOutcome: CellOutcome?
    public var minimalOutcome: CellOutcome?
    public var completePrimaryDiagnostics: Int?
    public var minimalPrimaryDiagnostics: Int?
    public var screenCount: Int?
    public var batch: Int
    /// The verify pass's count (§5.6), set for pass-1 emitters once the verify pass is collected.
    public var verifyScreenCount: Int?

    enum CodingKeys: String, CodingKey {
        case packageId = "package_id", sha, status, reason
        case completeOutcome = "complete_outcome", minimalOutcome = "minimal_outcome"
        case completePrimaryDiagnostics = "complete_primary_diagnostics"
        case minimalPrimaryDiagnostics = "minimal_primary_diagnostics"
        case screenCount = "screen_count", batch
        case verifyScreenCount = "verify_screen_count"
    }

    public init(packageId: String, sha: String, status: ScreenStatus, reason: String? = nil,
                completeOutcome: CellOutcome? = nil, minimalOutcome: CellOutcome? = nil,
                completePrimaryDiagnostics: Int? = nil, minimalPrimaryDiagnostics: Int? = nil,
                screenCount: Int? = nil, batch: Int, verifyScreenCount: Int? = nil) {
        self.packageId = packageId
        self.sha = sha
        self.status = status
        self.reason = reason
        self.completeOutcome = completeOutcome
        self.minimalOutcome = minimalOutcome
        self.completePrimaryDiagnostics = completePrimaryDiagnostics
        self.minimalPrimaryDiagnostics = minimalPrimaryDiagnostics
        self.screenCount = screenCount
        self.batch = batch
        self.verifyScreenCount = verifyScreenCount
    }
}

public enum ScreenError: Error, CustomStringConvertible, Equatable {
    case incomplete(String, String)
    case denominatorMismatch(drawn: Int, sum: Int)
    case resolvedMismatch(String)
    case unverified(String)
    case duplicateResults(String)

    public var description: String {
        switch self {
        case .incomplete(let id, let what): "\(id): \(what)"
        case .denominatorMismatch(let drawn, let sum): "denominator sums to \(sum), but \(drawn) were drawn"
        case .resolvedMismatch(let id): "\(id): corpus/resolved already holds a different file; refusing to overwrite a pinned graph"
        case .duplicateResults(let id): "\(id): more than one result for this candidate"
        case .unverified(let id): "\(id): emitter has no verify-pass count; run `census screen collect --with-verify` first (§5.6)"
        }
    }
}

public struct Denominator: Equatable, Sendable {
    public var drawn: Int
    public var byStatus: [ScreenStatus: Int]
    public var notScreenableByReason: [String: Int]
    public var total: Int { byStatus.values.reduce(0, +) }

    static let order: [ScreenStatus] = [.unresolvable, .notScreenable, .clean, .emitter, .unstable, .minimalFailed, .infraError]

    public var rendered: String {
        var lines = ["drawn            \(drawn)"]
        for s in Self.order {
            lines.append(s.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0) + "\(byStatus[s] ?? 0)")
            if s == .notScreenable {
                for (reason, n) in notScreenableByReason.sorted(by: { $0.key < $1.key }) {
                    lines.append("  " + reason.padding(toLength: 15, withPad: " ", startingAt: 0) + "\(n)")
                }
            }
        }
        lines.append("sum              \(total)")
        return lines.joined(separator: "\n")
    }
}

/// The macOS screen that selects `S-emit` by measurement (ADR 0007). Pure: the commands in `census` do the I/O.
public enum Screen {
    public static let batchSize = 50
    public static let toolchain = Toolchain.macOSXcode
    /// `emitters.csv`'s `swift_version` column: which compiler and which count produced the number.
    public static let swiftVersionLabel = "xcode-27.0-minimal-diff"

    public static func primaryDiagnostics(_ records: [DiagnosticRecord]) -> Int {
        records.filter { $0.attribution == .primary && $0.severity != .note }.count
    }

    private struct Key: Hashable {
        var id: String
        var path: String
        var line: Int
        var col: Int
    }

    /// §5.3: the multiset difference `complete − minimal` over primary, non-note diagnostics.
    ///
    /// Severity is deliberately **not** in the key, unlike the A7 key (`DiagnosticKey`). A diagnostic can be a warning
    /// under `minimal` and an error under `complete`, and strict checking did not add it.
    public static func screenCount(complete: [DiagnosticRecord], minimal: [DiagnosticRecord]) -> Int {
        func counts(_ records: [DiagnosticRecord]) -> [Key: Int] {
            records.filter { $0.attribution == .primary && $0.severity != .note }.reduce(into: [:]) {
                $0[Key(id: $1.id ?? "text:\($1.text)", path: $1.path, line: $1.line, col: $1.col), default: 0] += 1
            }
        }
        let m = counts(minimal)
        return counts(complete).reduce(0) { $0 + max(0, $1.value - m[$1.key, default: 0]) }
    }

    /// §5.2 step 4, early exit: only a built complete cell with a primary diagnostic can have a non-zero count.
    public static func needsMinimal(_ complete: RunStore.LoadedCell) -> Bool {
        complete.record.outcome == .built && primaryDiagnostics(complete.diagnostics) > 0
    }

    public static func batchCount(_ total: Int) -> Int { (total + batchSize - 1) / batchSize }

    /// Batch `n` (1-based) of `items`, in their given order. Membership depends only on position, so an extension
    /// (D5) appends batches and never reshuffles a full earlier one.
    public static func batch<T>(_ n: Int, of items: [T]) -> [T] {
        let lo = (n - 1) * batchSize
        guard n >= 1, lo < items.count else { return [] }
        return Array(items[lo..<min(lo + batchSize, items.count)])
    }

    /// The screen picks its modes explicitly; `BuildInvocation.modes(for:)` never yields `minimal-v5`.
    public static func cells(_ packages: [CorpusPackage], mode: Mode) -> [PlannedCell] {
        packages.map { PlannedCell(package: $0, toolchain: toolchain, mode: mode) }
    }

    /// A swapped or foreign cell must never yield a count.
    private static func require(_ cell: RunStore.LoadedCell, for p: CorpusPackage, mode: Mode, as which: String) throws {
        guard cell.record.packageId == p.id, cell.record.mode == mode else {
            throw ScreenError.incomplete(p.id, "cell for \(cell.record.packageId) \(cell.record.mode.rawValue) passed as \(which)")
        }
    }

    /// §5.4. Throws rather than guess when a cell the status depends on is missing.
    public static func classify(package p: CorpusPackage, batch: Int, resolveFailure: String?,
                                complete: RunStore.LoadedCell?, minimal: RunStore.LoadedCell?) throws -> ScreenResult {
        var r = ScreenResult(packageId: p.id, sha: p.sha, status: .clean, batch: batch)
        guard let complete else {
            guard let resolveFailure else {
                throw ScreenError.incomplete(p.id, "no strict-complete-v5 cell and no recorded resolve failure")
            }
            r.status = .unresolvable
            r.reason = resolveFailure
            return r
        }
        try require(complete, for: p, mode: .strictCompleteV5, as: "complete")
        let completeCount = primaryDiagnostics(complete.diagnostics)
        r.completeOutcome = complete.record.outcome
        r.completePrimaryDiagnostics = completeCount
        switch complete.record.outcome {
        case .built:
            break
        case .infraError:
            r.status = .infraError
            r.reason = complete.record.note
            return r
        case .buildFailed, .unsupportedToolsVersion, .resolveFailed, .timeout:
            r.status = .notScreenable
            r.reason = complete.record.outcome.rawValue
            return r
        }
        guard completeCount > 0 else {
            r.screenCount = 0
            return r
        }
        guard let minimal else { throw ScreenError.incomplete(p.id, "complete has diagnostics but there is no minimal-v5 cell") }
        try require(minimal, for: p, mode: .minimalV5, as: "minimal")
        r.minimalOutcome = minimal.record.outcome
        r.minimalPrimaryDiagnostics = primaryDiagnostics(minimal.diagnostics)
        switch minimal.record.outcome {
        case .built:
            let n = screenCount(complete: complete.diagnostics, minimal: minimal.diagnostics)
            r.screenCount = n
            r.status = n > 0 ? .emitter : .clean
        case .infraError:
            r.status = .infraError
            r.reason = minimal.record.note
        default:
            r.status = .minimalFailed
            r.reason = minimal.record.outcome.rawValue
        }
        return r
    }

    /// §5.6. A pass-1 emitter whose verify-pass count or either cell outcome differs is `unstable`. Neither pass is
    /// preferred and nothing is averaged. Non-emitters were not re-run and are returned unchanged. A verify-pass
    /// `infra_error` is a machine fault: it is retried (thrown), never judged as package instability.
    public static func applyVerify(_ pass1: ScreenResult, package: CorpusPackage,
                                   complete: RunStore.LoadedCell?, minimal: RunStore.LoadedCell?) throws -> ScreenResult {
        guard pass1.status == .emitter else { return pass1 }
        guard complete != nil else { throw ScreenError.incomplete(pass1.packageId, "no verify-pass strict-complete-v5 cell") }
        if complete?.record.outcome == .infraError || minimal?.record.outcome == .infraError {
            throw ScreenError.incomplete(pass1.packageId, "verify-pass infra_error; retry the verify batch")
        }
        let v = try classify(package: package, batch: pass1.batch, resolveFailure: nil, complete: complete, minimal: minimal)
        var r = pass1
        r.verifyScreenCount = v.screenCount
        if v.screenCount != pass1.screenCount || v.completeOutcome != pass1.completeOutcome || v.minimalOutcome != pass1.minimalOutcome {
            r.status = .unstable
            r.reason = "verify pass: screen_count \(v.screenCount.map(String.init) ?? "none"), "
                + "complete \(v.completeOutcome?.rawValue ?? "none"), minimal \(v.minimalOutcome?.rawValue ?? "none")"
        }
        return r
    }

    /// The verify pass re-runs pass-1 emitters, in candidate order. `unstable` is included so the list is the same
    /// whether it is read before or after `collect --with-verify` (an unstable result was a pass-1 emitter).
    public static func verifyPackages(results: [ScreenResult], candidates: [CorpusPackage]) -> [CorpusPackage] {
        let ids = Set(results.filter { $0.status == .emitter || $0.status == .unstable }.map(\.packageId))
        return candidates.filter { ids.contains($0.id) }
    }

    /// §5.5: the counts must sum to the number drawn, with one result per candidate.
    public static func denominator(drawn: Int, results: [ScreenResult]) throws -> Denominator {
        let d = Denominator(
            drawn: drawn,
            byStatus: Dictionary(grouping: results, by: \.status).mapValues(\.count),
            notScreenableByReason: Dictionary(grouping: results.filter { $0.status == .notScreenable }, by: { $0.reason ?? "unknown" })
                .mapValues(\.count))
        var seen = Set<String>()
        if let dup = results.map(\.packageId).first(where: { !seen.insert($0).inserted }) {
            throw ScreenError.duplicateResults(dup)
        }
        guard d.total == drawn else { throw ScreenError.denominatorMismatch(drawn: drawn, sum: d.total) }
        return d
    }

    /// `Selection.parseSPICSV`-compatible (§5.5). The column is named `data_race_errors` after SPI's export; here it
    /// carries `screen_count`, which counts warnings as well as errors. Unstable emitters are not exported.
    public static func emittersCSV(results: [ScreenResult], candidates: [CorpusPackage], asOf: String) -> String {
        let urls = Dictionary(candidates.map { ($0.id, $0.url) }, uniquingKeysWith: { a, _ in a })
        var out = "# data_race_errors carries screen_count (ADR 0007); swift_version names the toolchain and the count\n"
        out += "package_url,data_race_errors,swift_version,as_of\n"
        for r in results where r.status == .emitter {
            guard let url = urls[r.packageId], let n = r.screenCount else { continue }
            out += "\(url),\(n),\(swiftVersionLabel),\(asOf)\n"
        }
        return out
    }

    /// A screen id ends in its date (`screen-2026-10-10`), which becomes `emitters.csv`'s `as_of`.
    public static func date(fromScreenId id: String) -> String? {
        let s = String(id.suffix(10))
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard s.count == 10, parts.map(\.count) == [4, 2, 2], parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return s
    }

    public struct Selected: Sendable {
        public var entries: [CorpusPackage]
        public var emitters: Int
        public var perTertile: [Selection.Tertile: Int]
    }

    /// §5.7. Tertiles over the stable emitters, at each candidate's screened SHA (G1). Fewer than `count`, or an
    /// empty tertile, yields what exists: never padded. Refuses emitters that were never verified (§5.6).
    public static func selectEmit(results: [ScreenResult], candidates: [CorpusPackage], screenId: String,
                                  seed: UInt64, count: Int) throws -> Selected {
        let emitters = results.filter { $0.status == .emitter }
        if let unverified = emitters.first(where: { $0.verifyScreenCount == nil }) {
            throw ScreenError.unverified(unverified.packageId)
        }
        let byId = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // `SPIRow` is named for SPI's export; here `errors` carries the screen count. Renaming it is out of scope.
        let rows = emitters.compactMap { r -> SPIRow? in
            guard let p = byId[r.packageId], let n = r.screenCount else { return nil }
            return SPIRow(url: p.url, errors: n, swiftVersion: swiftVersionLabel, asOf: "")
        }
        let byURL = Dictionary(candidates.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var perTertile: [Selection.Tertile: Int] = [:]
        var entries: [CorpusPackage] = []
        for (row, tertile) in Selection.sampleAcrossDistribution(rows: rows, count: count, seed: seed) {
            guard let c = byURL[row.url] else { continue }
            perTertile[tertile, default: 0] += 1
            entries.append(CorpusPackage(
                id: c.id, url: c.url, sha: c.sha, stratum: .emit, platforms: [.linuxSPM, .macosSPM],
                selection: "seed=\(seed) \(tertile.rawValue)-tertile of \(rows.count) stable emitters; "
                    + "screen \(screenId) count \(row.errors); screened SHA (ADR 0007)",
                screenId: screenId, screenCountAtSelection: row.errors))
        }
        return Selected(entries: entries, emitters: rows.count, perTertile: perTertile)
    }

    /// §5.7 and G1: the matrix must build the graph that was screened, so each vendored file is copied byte for byte
    /// and never re-resolved. Checks everything before writing anything, and refuses to replace a different
    /// existing file: a pinned graph is never changed as a drive-by.
    public static func copyResolved(_ packages: [CorpusPackage], from source: URL, to destination: URL) throws {
        let decoder = JSONDecoder()
        let sourceProvenance = try decoder.decode([String: ResolvedProvenance].self,
                                                  from: Data(contentsOf: source.appendingPathComponent("provenance.json")))
        let destinationProvenanceURL = destination.appendingPathComponent("provenance.json")
        var destinationProvenance: [String: ResolvedProvenance] = [:]
        if FileManager.default.fileExists(atPath: destinationProvenanceURL.path) {
            destinationProvenance = try decoder.decode([String: ResolvedProvenance].self, from: Data(contentsOf: destinationProvenanceURL))
        }
        var writes: [(URL, Data)] = []
        for p in packages {
            let name = "\(p.slug).resolved"
            let bytes = try Data(contentsOf: source.appendingPathComponent(name))
            let target = destination.appendingPathComponent(name)
            if let existing = try? Data(contentsOf: target), existing != bytes { throw ScreenError.resolvedMismatch(p.id) }
            guard let provenance = sourceProvenance[p.id] else { throw ScreenError.incomplete(p.id, "no provenance entry in \(source.path)") }
            writes.append((target, bytes))
            destinationProvenance[p.id] = provenance
        }
        for (url, bytes) in writes { try bytes.write(to: url) }
        try RunStore(root: destination).write(destinationProvenance, to: destinationProvenanceURL)
    }
}
