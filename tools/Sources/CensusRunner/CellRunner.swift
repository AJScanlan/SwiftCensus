import CensusCore
import CryptoKit
import DiagParse
import Foundation

public struct CellLimits: Sendable {
    public var cpus: Int
    public var memoryGB: Int
    public var timeout: TimeInterval
    public init(cpus: Int = 4, memoryGB: Int = 6, timeout: TimeInterval = 45 * 60) {
        self.cpus = cpus
        self.memoryGB = memoryGB
        self.timeout = timeout
    }
}

/// The fixed in-container package root. Every cell sees the same path, so attribution is a prefix test.
public let containerPackageRoot = "/pkg"

/// Runs one `(package, toolchain, mode)` cell in a fresh container (F3: Linux is always
/// containerised; F4: clean tree, no incremental reuse) and writes its record. Never throws:
/// a cell that cannot run is recorded as `infra_error`, so no cell is a silent gap.
public struct CellRunner: Sendable, CellExecuting {
    public var sources: SourceCache
    public var resolvedDirectory: URL
    public var store: RunStore
    public var scratch: URL
    public var limits: CellLimits
    public var runId: String

    public init(sources: SourceCache, resolvedDirectory: URL, store: RunStore, scratch: URL,
                limits: CellLimits, runId: String) {
        self.sources = sources
        self.resolvedDirectory = resolvedDirectory
        self.store = store
        self.scratch = scratch
        self.limits = limits
        self.runId = runId
    }

    public func run(package: CorpusPackage, toolchain: Toolchain, mode: Mode, imageID: String?) async -> CellRecord {
        let started = Date()
        let arguments = BuildInvocation.swiftBuildArguments(mode: mode)
        var record = CellRecord(
            packageId: package.id, sha: package.sha, stratum: package.stratum, toolchain: toolchain.name,
            mode: mode, platform: .linuxSPM, outcome: .infraError, exitCode: nil,
            startedAt: ISO8601DateFormatter().string(from: started), durationSeconds: 0,
            invocation: arguments, image: toolchain.image)
        record.imageID = imageID

        let cellDir = store.cellDirectory(toolchain: toolchain.name, mode: mode, slug: package.slug)
        let name = containerName(package: package, toolchain: toolchain, mode: mode)
        do {
            try await execute(package: package, toolchain: toolchain, mode: mode, arguments: arguments,
                              cellDir: cellDir, record: &record)
        } catch {
            record.outcome = .infraError
            record.note = "\(error)"
        }
        _ = try? await Shell.run("docker", ["rm", "-f", name])
        record.durationSeconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
        try? store.write(record, to: cellDir.appendingPathComponent("cell.json"))
        return record
    }

    private func execute(package: CorpusPackage, toolchain: Toolchain, mode: Mode, arguments: [String],
                         cellDir: URL, record: inout CellRecord) async throws {
        let fm = FileManager.default
        let slug = package.slug
        let source = try await sources.ensure(package)
        let resolved = resolvedDirectory.appendingPathComponent("\(slug).resolved")
        // F1: never build against an unpinned dependency graph.
        guard fm.fileExists(atPath: resolved.path) else {
            throw CellError.missingVendoredResolved(package.id)
        }
        record.resolvedFileSHA256 = SHA256.hash(data: try Data(contentsOf: resolved))
            .map { String(format: "%02x", $0) }.joined()

        let name = containerName(package: package, toolchain: toolchain, mode: mode)
        let raw = scratch.appendingPathComponent("raw-\(name)")
        let extracted = scratch.appendingPathComponent("dia-\(name)")
        for dir in [raw, extracted] { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        defer { for dir in [raw, extracted] { try? fm.removeItem(at: dir) } }

        _ = try? await Shell.run("docker", ["rm", "-f", name])
        try await Shell.check("docker", [
            "create", "--name", name,
            "--cpus", "\(limits.cpus)", "--memory", "\(limits.memoryGB)g",
            "-v", "census-modcache-\(toolchain.name):/modcache",
            "-v", "census-swiftpm-cache:/swiftpm-cache",
            "-w", containerPackageRoot,
            toolchain.image, "bash", "-c", Self.script(arguments: arguments),
        ])

        // Stage source without .git, under /pkg. bsdtar's -s renames the leading "." entry.
        try await Shell.check("/bin/sh", [
            "-c", "tar -cf - --no-xattrs --no-mac-metadata --exclude .git -s '|^\\.|pkg|' -C \(Self.quote(source.path)) . | docker cp - \(name):/",
        ])
        try await Shell.check("docker", ["cp", resolved.path, "\(name):\(containerPackageRoot)/Package.resolved"])

        let start = try await Shell.run("docker", ["start", "-a", name], timeout: limits.timeout)
        if start.timedOut { _ = try? await Shell.run("docker", ["kill", name]) }
        try await Shell.check("docker", ["cp", "\(name):/out/.", raw.path])

        try await CellIngest.ingest(
            raw: raw, extracted: extracted, cellDir: cellDir, timedOut: start.timedOut,
            packageRoot: containerPackageRoot, store: store, record: &record)
    }

    func containerName(package: CorpusPackage, toolchain: Toolchain, mode: Mode) -> String {
        "census-\(runId)-\(package.slug)-\(toolchain.name)-\(mode.rawValue)".replacingOccurrences(of: ".", with: "_")
    }

    /// Runs inside the container. Always exits 0 so `docker start -a` succeeds and the build's own
    /// exit code is read from `/out/exit-code`.
    static func script(arguments: [String]) -> String {
        let build = arguments.map(quote).joined(separator: " ")
        return """
        mkdir -p /out
        { swift --version; uname -m; } > /out/env.txt 2>&1
        cd \(containerPackageRoot)
        \(build) > /out/build.log 2>&1
        echo $? > /out/exit-code
        find .build -name '*.dia' > /out/dia-list.txt 2>/dev/null
        if [ -s /out/dia-list.txt ]; then tar -czf /out/dia.tar.gz -T /out/dia-list.txt; fi
        exit 0
        """
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum CellError: Error, CustomStringConvertible {
    case missingVendoredResolved(String)
    public var description: String {
        switch self {
        case .missingVendoredResolved(let id):
            "\(id): no vendored corpus/resolved file; refusing to build against an unpinned dependency graph (F1)"
        }
    }
}
