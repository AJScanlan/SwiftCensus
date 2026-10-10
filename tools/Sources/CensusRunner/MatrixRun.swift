import CensusCore
import CryptoKit
import Foundation

/// What `MatrixRun` needs from a platform runner. One implementation per platform (Docker for Linux,
/// a Lima guest for macOS); the schema, parser and comparison are shared.
public protocol CellExecuting: Sendable {
    var store: RunStore { get }
    func run(package: CorpusPackage, toolchain: Toolchain, mode: Mode, imageID: String?) async -> CellRecord
}

public struct MatrixSelection: Sendable {
    public var platform: Platform
    public var toolchains: [Toolchain]
    public var packageIds: Set<String>?
    public var strata: Set<Stratum>?
    public var modes: Set<Mode>?
    public init(platform: Platform = .linuxSPM, toolchains: [Toolchain] = Toolchain.matrix,
                packageIds: Set<String>? = nil, strata: Set<Stratum>? = nil, modes: Set<Mode>? = nil) {
        self.platform = platform
        self.toolchains = toolchains
        self.packageIds = packageIds
        self.strata = strata
        self.modes = modes
    }
}

public struct PlannedCell: Sendable {
    public var package: CorpusPackage
    public var toolchain: Toolchain
    public var mode: Mode
}

public enum MatrixRun {
    /// Cells ordered by toolchain then package, so a toolchain's shared module cache warms once.
    public static func plan(manifest: CorpusManifest, selection: MatrixSelection) -> [PlannedCell] {
        var cells: [PlannedCell] = []
        for toolchain in selection.toolchains {
            for package in manifest.packages {
                guard package.skipReason == nil, package.platforms.contains(selection.platform) else { continue }
                if let ids = selection.packageIds, !ids.contains(package.id) { continue }
                if let strata = selection.strata, !strata.contains(package.stratum) { continue }
                for mode in BuildInvocation.modes(for: package.stratum) {
                    if let modes = selection.modes, !modes.contains(mode) { continue }
                    cells.append(PlannedCell(package: package, toolchain: toolchain, mode: mode))
                }
            }
        }
        return cells
    }

    public static func imageID(_ image: String) async -> String? {
        let r = try? await Shell.run("docker", ["image", "inspect", "--format", "{{.Id}}", image])
        guard let r, r.succeeded else { return nil }
        return r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Executes the plan with bounded parallelism. Existing cells are skipped unless `force`, which
    /// makes an interrupted run resumable.
    public static func execute(
        cells: [PlannedCell], runner: any CellExecuting, jobs: Int, force: Bool,
        imageID resolveImageID: @escaping @Sendable (String) async -> String? = { await MatrixRun.imageID($0) },
        progress: @escaping @Sendable (String) -> Void
    ) async {
        let pending = cells.filter {
            force || !runner.store.hasCell(toolchain: $0.toolchain.name, mode: $0.mode, slug: $0.package.slug)
        }
        progress("\(pending.count) cells to run (\(cells.count - pending.count) already present)")
        var imageIDs: [String: String?] = [:]
        for t in Set(pending.map(\.toolchain.image)) { imageIDs[t] = await resolveImageID(t) }

        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            var running = 0
            func launch() {
                guard let cell = iterator.next() else { return }
                running += 1
                let id = imageIDs[cell.toolchain.image] ?? nil
                group.addTask {
                    let record = await runner.run(package: cell.package, toolchain: cell.toolchain,
                                                  mode: cell.mode, imageID: id)
                    let n = await counter.next()
                    progress("[\(n)/\(pending.count)] \(cell.toolchain.name) \(cell.mode.rawValue) \(cell.package.id): "
                        + "\(record.outcome.rawValue) \(Int(record.durationSeconds))s "
                        + "(errors \(record.tally.primaryErrors), warnings \(record.tally.primaryWarnings))"
                        + (record.note.map { " — \($0.prefix(160))" } ?? ""))
                }
            }
            for _ in 0..<max(1, jobs) { launch() }
            while await group.next() != nil {
                running -= 1
                launch()
            }
        }
    }

    public static func sha256Hex(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

private actor Counter {
    private var n = 0
    func next() -> Int { n += 1; return n }
}
