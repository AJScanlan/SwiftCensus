import Foundation

/// How a `(package, toolchain, mode)` cell ended. A failed cell is data, never a silent gap.
public enum CellOutcome: String, Codable, Sendable {
    /// Build exited 0.
    case built
    /// Build exited non-zero after resolving. Its diagnostics are captured and committed, but are not a frequency
    /// source (ADR 0010 rule 1).
    case buildFailed = "build_failed"
    /// Dependency resolution failed (e.g. the vendored `Package.resolved` could not be honoured).
    case resolveFailed = "resolve_failed"
    /// The package's `swift-tools-version` is newer than this toolchain. Not a failure of the
    /// package or the instrument: that column simply cannot measure it.
    case unsupportedToolsVersion = "unsupported_tools_version"
    case timeout
    /// The instrument failed (Docker, network), not the package.
    case infraError = "infra_error"
}

/// The measurement modes (ADR 0002). `v5` is the only frequency source.
public enum Mode: String, Codable, Sendable, CaseIterable {
    case strictCompleteV5 = "strict-complete-v5"
    /// SPI-comparable; retained for comparability and never a frequency source.
    case strictCompleteDeclared = "strict-complete-declared"
    /// ADR 0007's screen baseline: `-strict-concurrency=minimal` with `-swift-version 5` forced. Never a corpus mode
    /// and never a frequency source; it exists only to be subtracted from `strict-complete-v5`.
    case minimalV5 = "minimal-v5"
}

public struct DiagnosticTally: Codable, Equatable, Sendable {
    public var primaryErrors = 0
    public var primaryWarnings = 0
    public var primaryNotes = 0
    public var transitive = 0
    public var generated = 0
    public var external = 0

    enum CodingKeys: String, CodingKey {
        case primaryErrors = "primary_errors", primaryWarnings = "primary_warnings"
        case primaryNotes = "primary_notes", transitive, generated, external
    }

    public init() {}

    public init(records: [DiagnosticRecord]) {
        for r in records {
            switch r.attribution {
            case .primary:
                switch r.severity {
                case .error, .fatal: primaryErrors += 1
                case .warning: primaryWarnings += 1
                case .note: primaryNotes += 1
                case .remark, .ignored: break
                }
            case .transitive: transitive += 1
            case .generated: generated += 1
            case .external: external += 1
            }
        }
    }
}

/// One cell's run record. F7: stores the invocation, toolchain string, triple and platform so
/// the measurement — not just the corpus — is pinned.
public struct CellRecord: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var packageId: String
    public var sha: String
    public var stratum: Stratum
    public var toolchain: String
    public var mode: Mode
    public var platform: Platform
    public var outcome: CellOutcome
    public var exitCode: Int?
    public var startedAt: String
    public var durationSeconds: Double
    /// The exact `swift build` argument list.
    public var invocation: [String]
    /// First `-module-name` compile command from the verbose build log: the resolved frontend invocation.
    public var frontendInvocationSample: String?
    public var toolchainVersion: String?
    public var targetTriple: String?
    public var image: String
    public var imageID: String?
    public var resolvedFileSHA256: String?
    public var testTargetsBuilt = false
    /// macOS cells only (F7): the guest OS build and the Xcode build that produced the measurement.
    public var osBuild: String?
    public var xcodeBuild: String?
    public var diaFilesFound = 0
    public var diaFilesUnreadable = 0
    public var diaFilesEmpty = 0
    public var tally = DiagnosticTally()
    public var note: String?

    public init(
        packageId: String, sha: String, stratum: Stratum, toolchain: String, mode: Mode, platform: Platform,
        outcome: CellOutcome, exitCode: Int?, startedAt: String, durationSeconds: Double, invocation: [String],
        image: String
    ) {
        self.packageId = packageId
        self.sha = sha
        self.stratum = stratum
        self.toolchain = toolchain
        self.mode = mode
        self.platform = platform
        self.outcome = outcome
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.invocation = invocation
        self.image = image
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case packageId = "package_id", sha, stratum, toolchain, mode, platform, outcome
        case exitCode = "exit_code", startedAt = "started_at", durationSeconds = "duration_seconds"
        case invocation
        case frontendInvocationSample = "frontend_invocation_sample"
        case toolchainVersion = "toolchain_version", targetTriple = "target_triple"
        case image, imageID = "image_id", resolvedFileSHA256 = "resolved_file_sha256"
        case testTargetsBuilt = "test_targets_built"
        case osBuild = "os_build", xcodeBuild = "xcode_build"
        case diaFilesFound = "dia_files_found", diaFilesUnreadable = "dia_files_unreadable"
        case diaFilesEmpty = "dia_files_empty"
        case tally, note
    }
}

/// Written once per run, next to the cells.
public struct RunManifest: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var runId: String
    public var startedAt: String
    public var toolsGitCommit: String?
    public var toolsGitDirty: Bool?
    public var corpusManifestSHA256: String
    public var hostPlatform: String
    public var dockerServerVersion: String?
    public var toolchains: [String: String]
    public var modes: [Mode]
    public var platform: Platform
    public var testTargetsBuilt = false

    public init(
        runId: String, startedAt: String, toolsGitCommit: String?, toolsGitDirty: Bool?,
        corpusManifestSHA256: String, hostPlatform: String, dockerServerVersion: String?,
        toolchains: [String: String], modes: [Mode], platform: Platform
    ) {
        self.runId = runId
        self.startedAt = startedAt
        self.toolsGitCommit = toolsGitCommit
        self.toolsGitDirty = toolsGitDirty
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.hostPlatform = hostPlatform
        self.dockerServerVersion = dockerServerVersion
        self.toolchains = toolchains
        self.modes = modes
        self.platform = platform
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", runId = "run_id", startedAt = "started_at"
        case toolsGitCommit = "tools_git_commit", toolsGitDirty = "tools_git_dirty"
        case corpusManifestSHA256 = "corpus_manifest_sha256"
        case hostPlatform = "host_platform", dockerServerVersion = "docker_server_version"
        case toolchains, modes, platform
        case testTargetsBuilt = "test_targets_built"
    }
}
