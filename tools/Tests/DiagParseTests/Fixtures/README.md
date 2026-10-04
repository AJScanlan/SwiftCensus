# DiagParse fixtures

`probe-tree/` holds real `.dia` files produced by the Swift 6.4 compiler
(`swiftc -c … -serialize-diagnostics`, flags per CLAUDE.md's canonical invocation) from two
source files compiled under the package root `/private/tmp/probe/pkg`:

- `Probe.dia` — `Sources/Probe/Probe.swift`: two primary errors, four notes.
- `Probe-primary-emit-module.dia` — a byte-identical copy, standing in for the second frontend
  job that re-emits the same diagnostics. Dedup must collapse it.
- `Dep.dia` — `.build/checkouts/Dep/Sources/Dep/Dep.swift`: must classify as `transitive` (F2).

`probe-tree.golden.json` is the reviewed expected output. It was checked by hand against the
compiler's own rendered output for the same source. Regenerate with `UPDATE_GOLDEN=1` (writes to
`/tmp/probe-tree.golden.json`), then **diff and review** before copying it over: a golden file
that was regenerated rather than reviewed asserts nothing.

Note the second primary error carries no `group`: `actor_isolated_non_self_reference` is an
ungrouped diagnostic, which is the case A5's `ungrouped` class counts.
