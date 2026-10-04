# corpus/

- `packages.yaml` — the pinned corpus. Every entry has a 40-character SHA (P7). Edited by
  `census select`; a SHA bump is a documented operation with a fresh baseline run, never a drive-by.
- `resolved/<id>.resolved` — the vendored `Package.resolved` per entry (F1), and
  `resolved/provenance.json` saying whether each came from upstream or was generated, and when.
- `suppression.json` — SuppressionScan output (A10), derived from the pinned SHAs.
- `spi-counts.csv` — **not yet present; supplied by the owner.** Input to `census select emit`.

## `spi-counts.csv`

```
package_url,data_race_errors,swift_version,as_of
https://github.com/owner/repo,12,6.1,2025-05-07
```

One row per package, taken from SPI's own published "Swift 6 data race errors" figure. Rows with
`data_race_errors` of 0 may be included; they are ignored for `S-emit` and are useful for audit.
SPI cannot be fetched by the instrument (Cloudflare challenge; see ADR 0004 §4).

```
census select emit --seed <n> --count 30
census resolve --package <new ids>
census run --run-id <date>
```
