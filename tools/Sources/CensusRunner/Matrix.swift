import CensusCore
import Foundation

public struct Toolchain: Equatable, Sendable {
    public var name: String
    public var image: String
    public init(name: String, image: String) {
        self.name = name
        self.image = image
    }

    /// A6, as restated for Linux by ADR 0003 option A. 6.0 is dropped: no `-print-diagnostic-groups`.
    public static let matrix: [Toolchain] = [
        Toolchain(name: "6.1", image: "swift:6.1"),
        Toolchain(name: "6.2", image: "swift:6.2"),
        Toolchain(name: "6.3", image: "swift:6.3"),
        Toolchain(name: "6.4", image: "swift:6.4"),
        Toolchain(name: "nightly", image: "swiftlang/swift:nightly-main-jammy"),
    ]

    /// The macOS column (ADR 0006): the Swift that ships in Xcode 27, inside the Lima guest. One column,
    /// because on macOS the toolchain and SDK are coupled (ADR 0003) and a macOS matrix would confound them.
    public static let macOSXcode = Toolchain(name: "xcode-27.0", image: "lima:census-macos")

    public static func named(_ name: String) -> Toolchain? { matrix.first { $0.name == name } }
}

public enum BuildInvocation {
    /// CLAUDE.md's canonical invocation, plus non-semantic additions: `-v` so the resolved frontend
    /// command lines are in the log (F7), a shared per-toolchain module cache (F4), `-serialize-diagnostics` (see below), and a shared
    /// SwiftPM dependency-mirror cache. None of these change which diagnostics are emitted.
    ///
    /// `strict-complete-declared` omits the forced `-swift-version 5` (ADR 0002) and is used only
    /// for SPI comparability on `S-anchor`. `minimal-v5` differs from `strict-complete-v5` only in the
    /// checking level (ADR 0007).
    public static func swiftBuildArguments(
        mode: Mode, cachePath: String = "/swiftpm-cache", moduleCachePath: String = "/modcache"
    ) -> [String] {
        var args = [
            "swift", "build", "-v", "--force-resolved-versions", "--cache-path", cachePath,
            "-Xswiftc", "-strict-concurrency=\(mode == .minimalV5 ? "minimal" : "complete")",
        ]
        if mode != .strictCompleteDeclared {
            args += ["-Xswiftc", "-swift-version", "-Xswiftc", "5"]
        }
        args += [
            "-Xswiftc", "-debug-diagnostic-names",
            "-Xswiftc", "-print-diagnostic-groups",
            "-Xswiftc", "-no-color-diagnostics",
            "-Xswiftc", "-diagnostic-style=llvm",
            "-Xswiftc", "-module-cache-path", "-Xswiftc", moduleCachePath,
            // Linux SwiftPM before 6.2 uses the native build system, which does not serialize
            // diagnostics on its own: without this flag a 6.1 cell has no .dia and silently reports
            // zero diagnostics (observed: 15 of 18 diagnostic-capable 6.1 cells). Later toolchains
            // already serialize and are unaffected.
            "-Xswiftc", "-serialize-diagnostics",
        ]
        return args
    }

    /// The modes a package is measured under: v5 for everything, plus `declared` on `S-anchor`
    /// (ROADMAP M1 item 3, with `swift6` replaced by `declared` per ADR 0002).
    public static func modes(for stratum: Stratum) -> [Mode] {
        stratum == .anchor ? [.strictCompleteV5, .strictCompleteDeclared] : [.strictCompleteV5]
    }
}
