import CensusCore
import Foundation

/// Spec 2026-10-11 §3.2. A macOS run's `S-emit` `strict-complete-v5` cells were built from the same SHA, resolved file,
/// guest image and Xcode as their screen pass-1 cells, so they must be A7 set-identical to them. If they are not, the
/// measurement that selected `S-emit` does not reproduce. Keys ignore stratum: screen cells say `screen`, runs `S-emit`.
public enum ScreenReproduction {
    public struct InputMismatch: Equatable, Sendable, CustomStringConvertible {
        public var packageId: String
        public var field: String
        public var screen: String
        public var run: String
        public var description: String { "\(packageId): \(field) differs (screen \(screen), run \(run))" }
    }

    public struct Result: Sendable {
        /// Non-empty means the two sides were built from different inputs, so nothing was compared.
        public var inputMismatches: [InputMismatch]
        public var comparison: RunComparison.Report?
        /// Cells outside the `S-emit` × `strict-complete-v5` keys, ignored on each side.
        public var ignoredScreenCells: Int
        public var ignoredRunCells: Int
        public var isReproduced: Bool { inputMismatches.isEmpty && comparison?.isSetIdentical == true }
    }

    public static func check(packages: [CorpusPackage],
                             screenCells: [RunStore.CellKey: RunStore.LoadedCell],
                             runCells: [RunStore.CellKey: RunStore.LoadedCell]) -> Result {
        func key(_ p: CorpusPackage) -> RunStore.CellKey {
            RunStore.CellKey(toolchain: Screen.toolchain.name, mode: .strictCompleteV5, packageId: p.id)
        }
        let keys = Set(packages.map(key))
        let left = screenCells.filter { keys.contains($0.key) }
        let right = runCells.filter { keys.contains($0.key) }

        var mismatches: [InputMismatch] = []
        for p in packages.sorted(by: { $0.id < $1.id }) {
            // A cell on one side only is the comparison's to report (only-in-left/right), not an input mismatch.
            guard let l = left[key(p)]?.record, let r = right[key(p)]?.record else { continue }
            // Differing values are a mismatch; so is a value neither side recorded, unless nil is allowed.
            func require(_ field: String, _ a: String?, _ b: String?, nilAllowed: Bool = false) {
                guard a != b || (a == nil && !nilAllowed) else { return }
                mismatches.append(InputMismatch(packageId: p.id, field: field, screen: a ?? "nil", run: b ?? "nil"))
            }
            if l.sha != p.sha || r.sha != p.sha {
                mismatches.append(InputMismatch(packageId: p.id, field: "sha (manifest \(p.sha))", screen: l.sha, run: r.sha))
            }
            require("resolved_file_sha256", l.resolvedFileSHA256, r.resolvedFileSHA256)
            require("image_id", l.imageID, r.imageID)
            require("xcode_build", l.xcodeBuild, r.xcodeBuild, nilAllowed: true)
        }
        return Result(inputMismatches: mismatches,
                      comparison: mismatches.isEmpty ? RunComparison.compare(left, right) : nil,
                      ignoredScreenCells: screenCells.count - left.count, ignoredRunCells: runCells.count - right.count)
    }
}
