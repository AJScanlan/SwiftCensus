import CensusCore
import Foundation
import TSCBasic
import TSCUtility

public struct UnreadableDia: Codable, Equatable, Sendable {
    public var path: String
    public var error: String
}

public struct ParseResult: Sendable {
    /// Deduplicated records in first-seen order. Notes follow their parent; `parent` indexes this array.
    public var records: [DiagnosticRecord]
    public var diaFilesFound: Int
    /// Zero-byte `.dia` files. A build system that aborts after one job fails leaves the sibling jobs'
    /// `.dia` files empty: the job never ran, so there are no diagnostics to lose. Counted, not an error.
    public var emptyDiaFiles: Int
    /// Non-empty files that could not be parsed: genuinely corrupt or truncated output.
    public var unreadable: [UnreadableDia]
}

enum UnreadableDiaError: Error { case tooShort(Int) }

private let minimumDiaBytes = 4

public enum DiagParse {
    /// Every `.dia` under `directory`, sorted so the parse order — and so first-seen order — is
    /// deterministic. The same diagnostic appears in several files (one per frontend job).
    public static func enumerateDia(under directory: Foundation.URL) -> [Foundation.URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [])
        else { return [] }
        return walker.compactMap { $0 as? Foundation.URL }
            .filter { $0.pathExtension == "dia" }
            .sorted { $0.path < $1.path }
    }

    /// Parses `.dia` files and deduplicates on `(id, path, line, col, severity)`.
    /// Note-to-parent linkage is positional within each file (ADR 0001).
    public static func parse(diaFiles: [Foundation.URL], packageRoot: String) -> ParseResult {
        var out: [DiagnosticRecord] = []
        var parentIndexByKey: [DiagnosticKey: Int] = [:]
        var noteKeysByParent: [Int: Set<DiagnosticKey>] = [:]
        var orphanKeys: Set<DiagnosticKey> = []
        var unreadable: [UnreadableDia] = []
        var empty = 0

        for url in diaFiles {
            let diagnostics: [SerializedDiagnostics.Diagnostic]
            do {
                let data = try Data(contentsOf: url)
                if data.isEmpty { empty += 1; continue }
                // TSC's bitstream reader traps (precondition) rather than throws on <= 4 bytes,
                // which would kill the whole run on one empty or truncated file.
                guard data.count > minimumDiaBytes else { throw UnreadableDiaError.tooShort(data.count) }
                diagnostics = try SerializedDiagnostics(bytes: ByteString(Array(data))).diagnostics
            } catch {
                unreadable.append(UnreadableDia(path: url.path, error: "\(error)"))
                continue
            }

            var currentParent: Int?
            for d in diagnostics {
                let record = makeRecord(d, packageRoot: packageRoot)
                if record.severity != .note {
                    if let existing = parentIndexByKey[record.key] {
                        currentParent = existing
                    } else {
                        out.append(record)
                        currentParent = out.count - 1
                        parentIndexByKey[record.key] = currentParent
                    }
                } else if let parent = currentParent {
                    guard noteKeysByParent[parent, default: []].insert(record.key).inserted else { continue }
                    out.append(adopt(record, parent: out[parent], parentIndex: parent))
                } else if orphanKeys.insert(record.key).inserted {
                    out.append(record)
                }
            }
        }
        // Notes were appended after later parents may have been; restore "notes follow parent".
        return ParseResult(
            records: reorderNotesAfterParents(out), diaFilesFound: diaFiles.count, emptyDiaFiles: empty,
            unreadable: unreadable)
    }

    /// A note with no source location (the compiler emits some, e.g. `nonsendable_function_type`)
    /// would classify as `external` and silently drop out of the primary distribution even though its
    /// parent is primary. It inherits the parent's attribution; its `path` stays `<unknown>`.
    static func adopt(_ note: DiagnosticRecord, parent: DiagnosticRecord, parentIndex: Int) -> DiagnosticRecord {
        var note = note
        note.parent = parentIndex
        if note.path == unknownPath { note.attribution = parent.attribution }
        return note
    }

    static let unknownPath = "<unknown>"

    private static func makeRecord(_ d: SerializedDiagnostics.Diagnostic, packageRoot: String) -> DiagnosticRecord {
        let split = MessageSuffix.split(d.text)
        let rawPath = d.location?.filename ?? unknownPath
        let (attribution, path) = d.location == nil
            ? (Attribution.external, rawPath)
            : PathAttribution.classify(path: rawPath, root: packageRoot)
        return DiagnosticRecord(
            id: split.id, text: split.message,
            severity: Severity(rawValue: "\(d.level)") ?? .error,
            group: d.category ?? split.group, groupURL: d.categoryURL,
            path: path, line: Int(d.location?.line ?? 0), col: Int(d.location?.column ?? 0),
            fixIts: d.fixIts.count, attribution: attribution, parent: nil)
    }

    /// A later `.dia` can contribute a new note for a parent first seen in an earlier file, so
    /// notes may sit after unrelated records. Stable-sort them back behind their parent and
    /// rewrite `parent` to the new indices.
    private static func reorderNotesAfterParents(_ records: [DiagnosticRecord]) -> [DiagnosticRecord] {
        var notesByParent: [Int: [DiagnosticRecord]] = [:]
        for r in records where r.parent != nil { notesByParent[r.parent!, default: []].append(r) }
        var result: [DiagnosticRecord] = []
        for (oldIndex, r) in records.enumerated() where r.parent == nil {
            result.append(r)
            let newIndex = result.count - 1
            for var note in notesByParent[oldIndex] ?? [] {
                note.parent = newIndex
                result.append(note)
            }
        }
        return result
    }
}
