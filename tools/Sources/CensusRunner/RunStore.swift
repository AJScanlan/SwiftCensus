import CensusCore
import Foundation

/// On-disk layout of one run:
///
///     runs/<run-id>/run.json
///     runs/<run-id>/<toolchain>/<mode>/<package-slug>/{cell.json, diagnostics.json, build.log.gz, dia.tar.gz}
///
/// Raw bytes (`build.log.gz`, `dia.tar.gz`) are committed beside the parsed JSON so the pipeline can
/// be re-derived without recompute if the parser turns out to be wrong.
public struct RunStore: Sendable {
    public var root: URL
    public init(root: URL) { self.root = root }

    public func cellDirectory(toolchain: String, mode: Mode, slug: String) -> URL {
        root.appendingPathComponent(toolchain).appendingPathComponent(mode.rawValue).appendingPathComponent(slug)
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Self.encoder().encode(value) + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    public struct LoadedCell: Sendable {
        public var record: CellRecord
        public var diagnostics: [DiagnosticRecord]
        public var directory: URL
    }

    public struct CellKey: Hashable, Sendable, Comparable, CustomStringConvertible {
        public var toolchain: String
        public var mode: Mode
        public var packageId: String
        public init(toolchain: String, mode: Mode, packageId: String) {
            self.toolchain = toolchain
            self.mode = mode
            self.packageId = packageId
        }
        public var description: String { "\(toolchain)/\(mode.rawValue)/\(packageId)" }
        public static func < (a: Self, b: Self) -> Bool { a.description < b.description }
    }

    public func hasCell(toolchain: String, mode: Mode, slug: String) -> Bool {
        FileManager.default.fileExists(
            atPath: cellDirectory(toolchain: toolchain, mode: mode, slug: slug).appendingPathComponent("cell.json").path)
    }

    /// Loads every cell under the run directory.
    public func loadCells() throws -> [CellKey: LoadedCell] {
        var out: [CellKey: LoadedCell] = [:]
        let decoder = JSONDecoder()
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        for case let url as URL in walker where url.lastPathComponent == "cell.json" {
            let record = try decoder.decode(CellRecord.self, from: Data(contentsOf: url))
            let dir = url.deletingLastPathComponent()
            let diagURL = dir.appendingPathComponent("diagnostics.json")
            let diagnostics = FileManager.default.fileExists(atPath: diagURL.path)
                ? try decoder.decode([DiagnosticRecord].self, from: Data(contentsOf: diagURL)) : []
            out[CellKey(toolchain: record.toolchain, mode: record.mode, packageId: record.packageId)] =
                LoadedCell(record: record, diagnostics: diagnostics, directory: dir)
        }
        return out
    }
}
