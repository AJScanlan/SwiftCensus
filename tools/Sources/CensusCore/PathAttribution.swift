import Foundation

public enum PathAttribution {
    /// Classifies a diagnostic's source path against the package root and returns the
    /// root-relative path where one exists.
    ///
    /// `root` is the package directory as the compiler saw it. The runner mounts every
    /// package at one fixed path, so this is a prefix test, not a filesystem lookup.
    public static func classify(path: String, root: String) -> (attribution: Attribution, path: String) {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path.hasPrefix(root + "/") else { return (.external, path) }
        let relative = String(path.dropFirst(root.count + 1))
        if relative.hasPrefix(".build/checkouts/") { return (.transitive, relative) }
        if relative.hasPrefix(".build/") { return (.generated, relative) }
        return (.primary, relative)
    }
}
