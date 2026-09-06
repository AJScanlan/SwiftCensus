# samples/

`m0.json` — the M0 capture spike output. Two real packages, one toolchain, produced by
the route ADR 0001 selected (serialized `.dia` via `TSCUtility.SerializedDiagnostics`).

It exists to demonstrate the pipeline end to end and to pin the shape of a diagnostic
record. It is **not** census data: two packages is not a corpus, and the corpus design
in ROADMAP A3 has not been built yet.

| Package | ref | primary diagnostics | notes | `.dia` files |
|---|---|---|---|---|
| jpsim/Yams | 5.4.0 | 48 | 91 | 39 |
| kean/Nuke | 12.8.0 | 0 | 0 | 73 |

Both were vetted for macro and build-plugin targets before being built, per ROADMAP F3.

Three things this sample already demonstrates:

- **Notes are 65% of all records.** Counting them as diagnostics would have inflated
  Yams' figure from 48 to 139. ROADMAP A8's exclusion rule is load-bearing, not tidiness.
- **The compiler proposed `nonisolated(unsafe)` 41 times** in one small package
  (`shared_state_nonisolated_unsafe`), tied with `add_globalactor_to_decl`. This is the
  remedy distribution A8 describes and it connects directly to A10's escape-hatch census.
- **`category` and `categoryURL` arrive as structured fields.** Every grouped diagnostic
  in this sample carried a docs.swift.org URL. Whether a group can exist *without* one —
  which A5's three-way split depends on — is not answered by this sample and remains open
  for M2.
