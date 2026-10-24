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

    /// A run refused before any cell is built: these images have no ID, and a cell without `image_id` cannot be tied to
    /// what it ran on (P3; spec 2026-10-18 §1.2).
    public struct UnresolvedImageError: Error, CustomStringConvertible {
        public var images: [String]
        public var description: String {
            "no image ID for \(images.joined(separator: ", ")): refusing to start the run (P3; spec 2026-10-18 §1.2)"
        }
    }

    /// Docker Hub's canonical form of a reference without a registry host: `swift:6.4` → `docker.io/library/swift:6.4`,
    /// `swiftlang/swift:x` → `docker.io/swiftlang/swift:x`. A reference that names a host is returned unchanged.
    public static func qualifiedReference(_ image: String) -> String {
        guard let slash = image.firstIndex(of: "/") else { return "docker.io/library/" + image }
        let first = image[..<slash]
        if first.contains(".") || first.contains(":") || first == "localhost" { return image }
        return "docker.io/" + image
    }

    /// The ID on the line of `docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}"` output that names exactly
    /// `image`. `<none>` tags never match.
    static func imageID(inListing listing: String, for image: String) -> String? {
        let want = qualifiedReference(image)
        for line in listing.split(separator: "\n") {
            guard let space = line.lastIndex(of: " ") else { continue }
            let reference = line[..<space].trimmingCharacters(in: .whitespaces)
            let id = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            if reference.hasSuffix(":<none>") || id.isEmpty { continue }
            if qualifiedReference(reference) == want { return id }
        }
        return nil
    }

    /// `inspect` of the qualified reference, retried; then the listing, retried. Nil only if both fail.
    static func resolveImageID(_ image: String, attempts: Int = 3, pause: Duration = .seconds(1),
                               inspect: (String) async -> String?, listing: () async -> String?) async -> String? {
        let reference = qualifiedReference(image)
        if let id = await firstResult(attempts: attempts, pause: pause, { await inspect(reference) }) { return id }
        return await firstResult(attempts: attempts, pause: pause) {
            guard let text = await listing() else { return nil }
            return imageID(inListing: text, for: image)
        }
    }

    /// The local image ID of `image`. On this Docker, `image inspect` of a bare `swift:` tag intermittently says "No such
    /// image" for an image that is present, sometimes for longer than a short retry (2026-10-11: 268 cells of
    /// `2026-10-11-rerun` got no `image_id`). The fully qualified reference and the listing did not fail in probes.
    public static func imageID(_ image: String) async -> String? {
        await resolveImageID(image, inspect: { reference in
            let r = try? await Shell.run("docker", ["image", "inspect", "--format", "{{.Id}}", reference])
            guard let r, r.succeeded else { return nil }
            return r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        }, listing: {
            let r = try? await Shell.run("docker", ["images", "--no-trunc", "--format", "{{.Repository}}:{{.Tag}} {{.ID}}"])
            guard let r, r.succeeded else { return nil }
            return r.stdoutString
        })
    }

    /// The first non-nil result of up to `attempts` calls, pausing between them.
    static func firstResult(attempts: Int, pause: Duration = .zero,
                            _ attempt: () async -> String?) async -> String? {
        for n in 1...attempts {
            if let value = await attempt() { return value }
            if (n < attempts) && (pause > .zero) { try? await Task.sleep(for: pause) }
        }
        return nil
    }

    /// Executes the plan with bounded parallelism. Existing cells are skipped unless `force`, which
    /// makes an interrupted run resumable. Every pending cell's image ID is resolved first: if any is unresolved, it
    /// throws `UnresolvedImageError` before a single cell is built. `beforeFirstCell` runs once, after the IDs resolve
    /// and before any cell, so a refused run leaves nothing it wrote there (e.g. `run.json`) behind.
    public static func execute(
        cells: [PlannedCell], runner: any CellExecuting, jobs: Int, force: Bool,
        imageID resolveImageID: @escaping @Sendable (String) async -> String? = { await MatrixRun.imageID($0) },
        beforeFirstCell: () async throws -> Void = {},
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        let pending = cells.filter {
            force || !runner.store.hasCell(toolchain: $0.toolchain.name, mode: $0.mode, slug: $0.package.slug)
        }
        progress("\(pending.count) cells to run (\(cells.count - pending.count) already present)")
        var imageIDs: [String: String] = [:]
        var unresolved: [String] = []
        for t in Set(pending.map(\.toolchain.image)).sorted() {
            if let id = await resolveImageID(t) { imageIDs[t] = id } else { unresolved.append(t) }
        }
        guard unresolved.isEmpty else { throw UnresolvedImageError(images: unresolved) }
        try await beforeFirstCell()

        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            var running = 0
            func launch() {
                guard let cell = iterator.next() else { return }
                running += 1
                let id = imageIDs[cell.toolchain.image]
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
