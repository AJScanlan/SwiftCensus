import CensusCore
import Foundation

/// Read-only source checkouts at the pinned SHA, shared by every cell of a package.
/// Cells never build here: each gets a copy inside a fresh container (F4).
public struct SourceCache: Sendable {
    public var root: URL
    public init(root: URL) { self.root = root }

    public func directory(for package: CorpusPackage) -> URL {
        root.appendingPathComponent(package.slug).appendingPathComponent(package.sha)
    }

    /// Fetches the pinned commit if absent and verifies HEAD equals the SHA.
    /// Fetches by SHA rather than by ref so a moved tag cannot change what is measured (P7).
    @discardableResult
    public func ensure(_ package: CorpusPackage) async throws -> URL {
        let dir = directory(for: package)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".census-complete").path) {
            return dir
        }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await Shell.check("git", ["init", "-q"], currentDirectory: dir)
        try await Shell.check("git", ["remote", "add", "origin", package.url], currentDirectory: dir)
        try await Shell.check("git", ["fetch", "-q", "--depth", "1", "origin", package.sha],
                              currentDirectory: dir, timeout: 600)
        // Sources are Swift; LFS-tracked assets are irrelevant to compilation and the host need not
        // have git-lfs installed, so the smudge filter is disabled rather than required.
        try await Shell.check("git", ["-c", "filter.lfs.smudge=", "-c", "filter.lfs.process=",
                                      "-c", "filter.lfs.required=false", "checkout", "-q", "FETCH_HEAD"],
                              currentDirectory: dir)
        let head = try await Shell.check("git", ["rev-parse", "HEAD"], currentDirectory: dir)
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == package.sha else {
            throw SourceCacheError.shaMismatch(package.id, expected: package.sha, actual: head)
        }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".gitmodules").path) {
            try await Shell.check("git", ["submodule", "update", "--init", "--recursive", "--depth", "1"],
                                  currentDirectory: dir, timeout: 600)
        }
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".census-complete").path, contents: Data())
        return dir
    }
}

public enum SourceCacheError: Error, CustomStringConvertible {
    case shaMismatch(String, expected: String, actual: String)
    public var description: String {
        switch self {
        case .shaMismatch(let id, let e, let a): "\(id): fetched \(a) but manifest pins \(e)"
        }
    }
}
