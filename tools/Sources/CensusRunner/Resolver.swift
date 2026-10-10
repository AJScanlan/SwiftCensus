import CensusCore
import Foundation

public struct ResolvedProvenance: Codable, Equatable, Sendable {
    /// `upstream`: the package commits a `Package.resolved` that still resolves under
    /// `--force-resolved-versions`. `generated`: resolved on `resolvedAt`, because upstream had none
    /// or it was stale. `none`: the package has no dependencies; the vendored file is an empty pin set.
    public var source: String
    public var toolchain: String
    public var resolvedAt: String
    public var sha256: String
    public var pinCount: Int

    enum CodingKeys: String, CodingKey {
        case source, toolchain, sha256
        case resolvedAt = "resolved_at"
        case pinCount = "pin_count"
    }
}

/// F1: a package SHA does not pin its dependency graph. This vendors a `Package.resolved` per
/// entry under `corpus/resolved/<slug>.resolved`, which every cell copies in and enforces with
/// `--force-resolved-versions`. Bumping one is a documented operation with a fresh baseline run.
public struct Resolver: Sendable {
    public var sources: SourceCache
    public var resolvedDirectory: URL
    public var scratch: URL
    public var toolchain: Toolchain

    public init(sources: SourceCache, resolvedDirectory: URL, scratch: URL, toolchain: Toolchain) {
        self.sources = sources
        self.resolvedDirectory = resolvedDirectory
        self.scratch = scratch
        self.toolchain = toolchain
    }

    /// G3: resume-safe. A package is done when its vendored file exists *and* provenance records it. Anything else
    /// (never tried, failed, or interrupted between the two writes) is pending. `force` re-resolves everything,
    /// which for the corpus is a documented operation with a fresh baseline run, never a drive-by.
    public static func pending(_ packages: [CorpusPackage], resolvedDirectory: URL,
                               provenance: [String: ResolvedProvenance], force: Bool) -> [CorpusPackage] {
        guard !force else { return packages }
        return packages.filter { p in
            provenance[p.id] == nil
                || !FileManager.default.fileExists(atPath: resolvedDirectory.appendingPathComponent("\(p.slug).resolved").path)
        }
    }

    /// Only a genuine SwiftPM dependency-resolution failure is a property of the package and may be recorded
    /// as `unresolvable`. Docker create/cp/start failures, timeouts and source-fetch failures are infrastructure:
    /// recording them would publish a Docker or network fault as package data.
    public static func isPackageFailure(_ error: Error) -> Bool {
        if case ResolverError.resolutionFailed = error { return true }
        return false
    }

    static let emptyResolved = "{\n  \"pins\" : [\n\n  ],\n  \"version\" : 3\n}\n"

    static let script = """
    mkdir -p /out
    cd /pkg
    if [ -f Package.resolved ]; then
      if swift package resolve --force-resolved-versions > /out/resolve.log 2>&1; then
        echo upstream > /out/source
      else
        rm -f Package.resolved
        swift package resolve > /out/resolve.log 2>&1 && echo generated > /out/source || echo failed > /out/source
      fi
    else
      swift package resolve > /out/resolve.log 2>&1 && echo generated > /out/source || echo failed > /out/source
    fi
    if [ -f Package.resolved ]; then cp Package.resolved /out/Package.resolved; fi
    exit 0
    """

    public func resolve(_ package: CorpusPackage) async throws -> ResolvedProvenance {
        let fm = FileManager.default
        let source = try await sources.ensure(package)
        let name = "census-resolve-\(package.slug)".replacingOccurrences(of: ".", with: "_")
        let raw = scratch.appendingPathComponent("resolve-\(package.slug)")
        try? fm.removeItem(at: raw)
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: raw) }

        _ = try? await Shell.run("docker", ["rm", "-f", name])
        try await Shell.check("docker", [
            "create", "--name", name, "-v", "census-swiftpm-cache:/swiftpm-cache",
            "-w", containerPackageRoot, toolchain.image, "bash", "-c", Self.script,
        ])
        do {
            try await Shell.check("/bin/sh", [
                "-c", "tar -cf - --no-xattrs --no-mac-metadata --exclude .git -s '|^\\.|pkg|' -C \(CellRunner.quote(source.path)) . | docker cp - \(name):/",
            ])
            try await Shell.check("docker", ["start", "-a", name], timeout: 20 * 60)
            try await Shell.check("docker", ["cp", "\(name):/out/.", raw.path])
        } catch {
            _ = try? await Shell.run("docker", ["rm", "-f", name])
            throw error
        }
        _ = try? await Shell.run("docker", ["rm", "-f", name])

        let outcome = (try? String(contentsOf: raw.appendingPathComponent("source"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "failed"
        guard outcome != "failed" else {
            let log = (try? String(contentsOf: raw.appendingPathComponent("resolve.log"), encoding: .utf8)) ?? ""
            throw ResolverError.resolutionFailed(package.id, String(log.suffix(800)))
        }

        let produced = raw.appendingPathComponent("Package.resolved")
        let destination = resolvedDirectory.appendingPathComponent("\(package.slug).resolved")
        try fm.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
        let data: Data
        let provenanceSource: String
        if fm.fileExists(atPath: produced.path) {
            data = try Data(contentsOf: produced)
            provenanceSource = outcome
        } else {
            data = Data(Self.emptyResolved.utf8)
            provenanceSource = "none"
        }
        try data.write(to: destination)
        let pins = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            .flatMap { ($0["pins"] as? [Any])?.count ?? (($0["object"] as? [String: Any])?["pins"] as? [Any])?.count } ?? 0
        return ResolvedProvenance(
            source: provenanceSource, toolchain: toolchain.name,
            resolvedAt: ISO8601DateFormatter().string(from: Date()),
            sha256: try MatrixRun.sha256Hex(of: destination), pinCount: pins)
    }
}

public enum ResolverError: Error, CustomStringConvertible {
    case resolutionFailed(String, String)
    public var description: String {
        switch self {
        case .resolutionFailed(let id, let tail): "\(id): dependency resolution failed:\n\(tail)"
        }
    }
}
