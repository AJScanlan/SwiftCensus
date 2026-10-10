import CensusCore
import CryptoKit
import Foundation

/// Runs one cell on the macOS guest. Same record schema, parser and classifier as the Linux runner
/// (`CellIngest`); only staging and execution differ.
///
/// Cells run one at a time in a single guest. Each cell unpacks into a fresh directory (F4: clean tree);
/// the SwiftPM mirror cache and the module cache are shared across cells in the run, as on Linux.
public struct MacCellRunner: Sendable, CellExecuting {
    public var vm: GuestVM
    public var sources: SourceCache
    public var resolvedDirectory: URL
    public var store: RunStore
    public var scratch: URL
    public var timeout: TimeInterval
    /// Identifies the guest image in each record, so a record names the exact macOS the cell ran on.
    public var imageID: String?

    public init(vm: GuestVM, sources: SourceCache, resolvedDirectory: URL, store: RunStore, scratch: URL,
                timeout: TimeInterval, imageID: String?) {
        self.vm = vm
        self.sources = sources
        self.resolvedDirectory = resolvedDirectory
        self.store = store
        self.scratch = scratch
        self.timeout = timeout
        self.imageID = imageID
    }

    public func run(package: CorpusPackage, toolchain: Toolchain, mode: Mode, imageID _: String?) async -> CellRecord {
        let started = Date()
        let clock = SuspendingClock()
        let start = clock.now
        let arguments = BuildInvocation.swiftBuildArguments(
            mode: mode, cachePath: GuestVM.swiftPMCache, moduleCachePath: GuestVM.moduleCache)
        var record = CellRecord(
            packageId: package.id, sha: package.sha, stratum: package.stratum, toolchain: toolchain.name,
            mode: mode, platform: .macosSPM, outcome: .infraError, exitCode: nil,
            startedAt: ISO8601DateFormatter().string(from: started), durationSeconds: 0,
            invocation: arguments, image: toolchain.image)
        record.imageID = imageID

        let cellDir = store.cellDirectory(toolchain: toolchain.name, mode: mode, slug: package.slug)
        do {
            try await execute(package: package, arguments: arguments, cellDir: cellDir, record: &record)
        } catch {
            record.outcome = .infraError
            record.note = "\(error)"
        }
        // Never leave a cell's tree behind: it would count against the guest's disk and could leak into the next cell.
        _ = try? await vm.shell("rm -rf \(GuestVM.packageRoot) \(GuestVM.outDirectory)")
        record.durationSeconds = Elapsed.seconds(start.duration(to: clock.now))
        try? store.write(record, to: cellDir.appendingPathComponent("cell.json"))
        return record
    }

    private func execute(package: CorpusPackage, arguments: [String], cellDir: URL, record: inout CellRecord) async throws {
        let fm = FileManager.default
        let slug = package.slug
        let source = try await sources.ensure(package)
        let resolved = resolvedDirectory.appendingPathComponent("\(slug).resolved")
        guard fm.fileExists(atPath: resolved.path) else { throw CellError.missingVendoredResolved(package.id) }
        record.resolvedFileSHA256 = SHA256.hash(data: try Data(contentsOf: resolved))
            .map { String(format: "%02x", $0) }.joined()

        let raw = scratch.appendingPathComponent("raw-mac-\(slug)")
        let extracted = scratch.appendingPathComponent("dia-mac-\(slug)")
        for dir in [raw, extracted] { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        defer { for dir in [raw, extracted] { try? fm.removeItem(at: dir) } }

        // Stage: a tarball of the pinned source (no .git), unpacked into a fresh directory.
        let archive = scratch.appendingPathComponent("src-\(slug)-\(package.sha.prefix(12)).tgz")
        if !fm.fileExists(atPath: archive.path) {
            try await Shell.check("tar", ["-czf", archive.path, "--no-xattrs", "--no-mac-metadata",
                                          "--exclude", ".git", "-C", source.path, "."])
        }
        let remoteArchive = "\(GuestVM.stageDirectory)/\(slug).tgz"
        try await vm.shell("rm -rf \(GuestVM.packageRoot) \(GuestVM.outDirectory); mkdir -p \(GuestVM.packageRoot)")
        try await vm.copyTo(archive, remote: remoteArchive)
        try await vm.shell("tar -xzf \(CellRunner.quote(remoteArchive)) -C \(GuestVM.packageRoot) && rm -f \(CellRunner.quote(remoteArchive))")
        try await vm.copyTo(resolved, remote: "\(GuestVM.packageRoot)/Package.resolved")

        let run = try await vm.shell(Self.script(arguments: arguments), timeout: timeout)
        if run.timedOut {
            // The local ssh was killed; the build is still running in the guest.
            _ = try? await vm.shell("pkill -9 -f swift-build; pkill -9 -f swift-frontend; pkill -9 -f swift-driver; true")
        }

        // Copy back whichever of the output files exist.
        let listing = try await vm.shell("ls \(GuestVM.outDirectory)").stdoutString.split(separator: "\n").map(String.init)
        for name in ["build.log", "exit-code", "env.txt", "dia.tar.gz"] where listing.contains(name) {
            try await vm.copyFrom(remote: "\(GuestVM.outDirectory)/\(name)", local: raw.appendingPathComponent(name))
        }

        try await CellIngest.ingest(
            raw: raw, extracted: extracted, cellDir: cellDir, timedOut: run.timedOut,
            packageRoot: GuestVM.packageRoot, store: store, record: &record)
    }

    /// Runs in the guest. Always exits 0; the build's own exit code is read from `exit-code`.
    static func script(arguments: [String]) -> String {
        let build = arguments.map(CellRunner.quote).joined(separator: " ")
        let out = GuestVM.outDirectory
        return """
        mkdir -p \(out)
        { swift --version; sw_vers; xcodebuild -version; uname -m; } > \(out)/env.txt 2>&1
        cd \(GuestVM.packageRoot)
        \(build) > \(out)/build.log 2>&1
        echo $? > \(out)/exit-code
        find .build -name '*.dia' > \(out)/dia-list.txt 2>/dev/null
        if [ -s \(out)/dia-list.txt ]; then tar -czf \(out)/dia.tar.gz -T \(out)/dia-list.txt; fi
        exit 0
        """
    }
}
