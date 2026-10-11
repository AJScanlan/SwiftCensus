# corpus/

- `packages.yaml` — the pinned corpus. Every entry has a 40-character SHA (P7). Edited by
  `census select`; a SHA bump is a documented operation with a fresh baseline run, never a drive-by.
- `resolved/<id>.resolved` — the vendored `Package.resolved` per entry (F1), and
  `resolved/provenance.json` saying whether each came from upstream or was generated, and when.
- `suppression.json` — SuppressionScan output (A10), derived from the pinned SHAs.
- `spi-counts.csv` — not present. Since ADR 0007 it is a validation join only (§ "Relationship to SPI
  data"), never a selection input for `S-emit`.

## `S-emit` provenance (ADR 0007)

`S-emit`'s 30 entries come from the macOS screen `screens/screen-2026-10-10/`, not from SPI. 300
candidates were drawn uniformly (seed `20261004`) and screened on Xcode 27.0. `screen_count` is the
number of primary diagnostics `strict-complete-v5` adds over `minimal-v5`. The 47 stable emitters were
sampled by tertile (seed `20261010`). Each entry records `screen_id` and `screen_count_at_selection`, is
pinned at the screened SHA, and its `resolved/*.resolved` file is the screened file, byte for byte.

```
census select emit --from-screen screen-2026-10-10 --seed 20261010 --count 30
census validate
```

`S-emit` is selected on the outcome (non-zero by construction). Never pool it with `S-control`
without stated weights.

## `spi-counts.csv` (validation join only)

```
package_url,data_race_errors,swift_version,as_of
https://github.com/owner/repo,12,6.1,2025-05-07
```

One row per package, taken from SPI's own published "Swift 6 data race errors" figure. Rows with
`data_race_errors` of 0 may be included; they are useful for the join.
SPI cannot be fetched by the instrument (Cloudflare challenge; see ADR 0004 §4).

If it arrives, it is joined per package against the screen's count. It does not re-draw `S-emit`.
