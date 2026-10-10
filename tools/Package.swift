// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-diagnostic-census",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "census", targets: ["census"]),
    ],
    dependencies: [
        // Pinned exactly: parts of TSC are being absorbed elsewhere (ADR 0001).
        .package(url: "https://github.com/apple/swift-tools-support-core.git", exact: "0.8.0"),
        // Pinned to the newest matrix toolchain (CLAUDE.md, A10).
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .target(name: "CensusCore"),
        .target(
            name: "DiagParse",
            dependencies: [
                "CensusCore",
                .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
            ]
        ),
        // Isolated so swift-syntax stays out of CensusCore's dependency graph (A10).
        .target(
            name: "SuppressionScan",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "CensusRunner",
            dependencies: [
                "CensusCore", "DiagParse", "SuppressionScan",
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .executableTarget(
            name: "census",
            dependencies: [
                "CensusCore", "CensusRunner", "DiagParse", "SuppressionScan",
                .product(name: "Yams", package: "Yams"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "CensusCoreTests", dependencies: ["CensusCore"]),
        .testTarget(name: "CensusRunnerTests", dependencies: ["CensusRunner"]),
        .testTarget(name: "DiagParseTests", dependencies: ["DiagParse"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SuppressionScanTests", dependencies: ["SuppressionScan"]),
    ]
)
