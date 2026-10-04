import Foundation
import SwiftParser
import SwiftSyntax

public enum SuppressionScan {
    /// Bump when the file-selection rule changes; recorded in every `PackageScan`.
    public static let scopeVersion = "heuristic-v1"

    /// Scans one source file. Syntactic only — nothing is compiled, so a scan cannot fail a matrix cell.
    public static func scan(source: String, path: String, isManifest: Bool? = nil) -> FileScan {
        let manifest = isManifest ?? isManifestFilename((path as NSString).lastPathComponent)
        let tree = Parser.parse(source: source)
        let visitor = Visitor(isManifest: manifest)
        visitor.walk(tree)

        let converter = SourceLocationConverter(fileName: path, tree: tree)
        return FileScan(
            path: path, isManifest: manifest, counts: visitor.counts,
            nonCommentLines: nonCommentLineCount(tree, converter),
            parsedCleanly: !tree.hasError)
    }

    /// Scans every in-scope `.swift` file under `root`. Paths in the result are root-relative.
    public static func scanPackage(root: URL) throws -> PackageScan {
        var files: [FileScan] = []
        let base = root.standardizedFileURL.path
        for url in swiftFiles(under: root) {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                // Unreadable as UTF-8: report it as an unclean parse rather than dropping it silently.
                files.append(FileScan(path: relative, isManifest: false, counts: SuppressionCounts(),
                                      nonCommentLines: 0, parsedCleanly: false))
                continue
            }
            files.append(scan(source: source, path: relative))
        }
        files.sort { $0.path < $1.path }

        var total = SuppressionCounts()
        for f in files { total += f.counts }
        // Manifests are scanned for `.unsafeFlags` but are not source: keep them out of the denominator.
        let lines = files.filter { !$0.isManifest }.reduce(0) { $0 + $1.nonCommentLines }
        let clean = files.isEmpty ? 1.0 : Double(files.filter(\.parsedCleanly).count) / Double(files.count)
        let nonManifestCount = total.uncheckedSendable + total.nonisolatedUnsafe + total.preconcurrencyImport
            + total.preconcurrencyDeclaration + total.assumeIsolated
        return PackageScan(
            scope: scopeVersion, files: files, counts: total, nonCommentLines: lines,
            cleanParseFraction: clean,
            perThousandLines: lines == 0 ? 0 : Double(nonManifestCount) * 1000 / Double(lines))
    }

    // MARK: - File selection

    /// Directory names excluded from the scan. Test targets are out (A11), as are examples and
    /// build state. This is a path heuristic, not the manifest's target graph; `scopeVersion`
    /// records that.
    static let excludedDirectories: Set<String> = [
        ".build", ".git", ".swiftpm", "Tests", "Test", "Examples", "Example", "Demo", "Demos",
        "Benchmarks", "Benchmark", "Fixtures", "node_modules",
    ]

    static func isExcluded(directory name: String) -> Bool {
        excludedDirectories.contains(name) || name.hasSuffix("Tests")
    }

    static func isManifestFilename(_ name: String) -> Bool {
        name == "Package.swift" || (name.hasPrefix("Package@swift-") && name.hasSuffix(".swift"))
    }

    static func swiftFiles(under root: URL) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        for case let url as Foundation.URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if isExcluded(directory: url.lastPathComponent) { walker.skipDescendants() }
            } else if url.pathExtension == "swift" {
                out.append(url)
            }
        }
        return out
    }

    // MARK: - Line counting

    private static func nonCommentLineCount(_ tree: SourceFileSyntax, _ converter: SourceLocationConverter) -> Int {
        var lines = Set<Int>()
        for token in tree.tokens(viewMode: .sourceAccurate) where token.tokenKind != .endOfFile {
            let start = converter.location(for: token.positionAfterSkippingLeadingTrivia).line
            let end = converter.location(for: token.endPositionBeforeTrailingTrivia).line
            guard start <= end else { continue }
            lines.formUnion(start...end)
        }
        return lines.count
    }

    // MARK: - Visitor

    private final class Visitor: SyntaxVisitor {
        var counts = SuppressionCounts()
        let isManifest: Bool

        init(isManifest: Bool) {
            self.isManifest = isManifest
            super.init(viewMode: .sourceAccurate)
        }

        /// `@preconcurrency` is an `AttributeSyntax` wherever it appears — on an import, a declaration,
        /// or inside a conformance clause (where it is nested in an `AttributedTypeSyntax`) — so it is
        /// counted here and only here. `@unchecked Sendable` needs its base type, so it is counted below.
        override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
            guard let name = node.attributeName.as(IdentifierTypeSyntax.self)?.name.text else { return .visitChildren }
            switch name {
            case "preconcurrency":
                if node.isInsideImport { counts.preconcurrencyImport += 1 } else { counts.preconcurrencyDeclaration += 1 }
            default: break
            }
            return .visitChildren
        }

        override func visit(_ node: AttributedTypeSyntax) -> SyntaxVisitorContinueKind {
            let isSendable = node.baseType.as(IdentifierTypeSyntax.self)?.name.text == "Sendable"
                || node.baseType.as(MemberTypeSyntax.self)?.name.text == "Sendable"
            for element in node.attributes {
                guard case .attribute(let attribute) = element,
                      let name = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text
                else { continue }
                if name == "unchecked", isSendable { counts.uncheckedSendable += 1 }
            }
            return .visitChildren
        }

        override func visit(_ node: DeclModifierSyntax) -> SyntaxVisitorContinueKind {
            if node.name.tokenKind == .keyword(.nonisolated), node.detail?.detail.text == "unsafe" {
                counts.nonisolatedUnsafe += 1
            }
            return .visitChildren
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            let callee: String?
            if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
                callee = member.declName.baseName.text
            } else if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
                callee = ref.baseName.text
            } else {
                callee = nil
            }
            if callee == "assumeIsolated" { counts.assumeIsolated += 1 }
            if callee == "unsafeFlags", isManifest { counts.unsafeFlags += 1 }
            return .visitChildren
        }
    }
}

private extension SyntaxProtocol {
    /// True when this node sits in an `import` declaration's attribute list.
    var isInsideImport: Bool {
        var current: Syntax? = Syntax(self).parent
        while let node = current {
            if node.is(ImportDeclSyntax.self) { return true }
            if node.is(DeclSyntax.self) || node.is(CodeBlockItemSyntax.self) { return false }
            current = node.parent
        }
        return false
    }
}
