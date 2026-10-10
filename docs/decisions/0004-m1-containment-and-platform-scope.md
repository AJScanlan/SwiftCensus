# ADR 0004 — M1 containment, platform scope, and the S-emit signal

**Status:** accepted for M1; items marked **needs confirmation** were decided by the agent
working under a standing "complete M1" goal and should be confirmed or reversed by the owner.
**Date:** 2026-10-04
**Milestone:** M1
**Amended by:** ADR 0006 (macOS VM: §1 and §2 no longer hold once a macOS run exists)
**Resolves:** ROADMAP F3 ("recorded in an ADR before M1"); ADR 0003 (open)
**Affects:** ROADMAP A3, A6, A12; ADR 0002

## 1. Containment (F3)

Building a corpus package runs its manifest, SwiftPM plugins and macros. F3 requires that this
never happen on a machine holding signing keys or personal data.

- **Linux cells always run in a container.** One fresh container per `(package, toolchain, mode)`
  cell, destroyed afterwards. Source is streamed in with `docker cp` as a tar without `.git`; nothing
  from the host is bind-mounted. The only shared state is two named volumes: a per-toolchain module
  cache (F4) and a SwiftPM dependency-mirror cache (git mirrors addressed by pinned revision, which
  carries no build output and so cannot contaminate a cell).
- **The container has network access.** Dependency fetch needs it. It mounts no credentials, but it
  is not network-isolated from the LAN. Corpus SHAs pinned (P7) and dependencies pinned (F1) bound
  *what* runs; they do not bound what that code can reach.
- **macOS cells do not run in M1.** The only macOS machine available is the owner's development
  machine, which holds signing keys and personal data. That is exactly what F3 forbids, so the
  `macos-spm` platform is not executed here. **Needs a decision before the macOS column runs:** a
  dedicated machine, a VM, or a runner. Nothing in the tooling is macOS-specific except the platform
  tag, and `platforms: [macos-spm]` entries are skipped by the Linux runner rather than failing.

## 2. Platform and toolchain scope (ADR 0003)

Docker is now installed, so ADR 0003 **option A** is available and is adopted for the
cross-toolchain axis: all five A6 columns run on Linux (aarch64 under Docker on Apple silicon),
where toolchain and SDK are not coupled:

| Column | Image |
|---|---|
| 6.1 | `swift:6.1` |
| 6.2 | `swift:6.2` |
| 6.3 | `swift:6.3` |
| 6.4 | `swift:6.4` |
| nightly | `swiftlang/swift:nightly-main-jammy` (floating tag; the image ID is recorded per cell) |

Consequences, stated so the published number is interpretable (F6):

- M1 measures **linux-spm only**. Linux counts are not summable with a future macOS run.
- Packages that need Apple SDKs will fail on Linux and are recorded as failed cells, not dropped.
  The Linux sample therefore under-represents Apple-framework packages; the macOS column (A12)
  is where they belong.
- Linux is **aarch64** here. `#if arch(...)` code and x86_64 are not covered. The target triple is
  recorded in every cell.
- ADR 0003's open item stands: identifier stability (G0) was verified on macOS 6.3/6.4/nightly. It
  must be re-checked on Linux; the 6.1 and 6.2 columns now run, so the whole A6 range can be checked.
- A12's "canonical column must be GA" is a **M3** question. `swift:6.4` is a release tag on Docker
  Hub and Xcode reports `27.0` without a beta suffix, which suggests 6.4 is now GA; **needs
  confirmation** before it is called canonical.

## 3. Modes

ROADMAP M1 item 3 specifies a `swift6` overlay on `S-anchor`. ADR 0002 deleted `swift6` and kept
`strict-complete-declared` for SPI comparability. This ADR follows ADR 0002: `S-anchor` runs
`strict-complete-v5` and `strict-complete-declared`; everything else runs `strict-complete-v5` only.
`declared` is never a frequency source.

## 4. S-emit signal

SPI's pages and data are served behind a Cloudflare managed challenge to every non-browser request
(`cf-mitigated: challenge`, including `/`, `/sitemap.xml` and badge URLs), and `robots.txt`
disallows `/api/`. The per-package "Swift 6 data race errors" count A3 selects `S-emit` on cannot
be fetched mechanically, and the instrument will not defeat a bot challenge.

**Decision (owner, 2026-10-04): the owner supplies SPI data.** `corpus/spi-counts.csv`, columns
`package_url,data_race_errors,swift_version,as_of`, consumed by `census select emit`. Until it
exists, **`S-emit` is empty and M1's exit condition is not met.** The instrument does not
substitute a self-measured signal: that would amend A3 and is the owner's call.

Open from ADR 0001 and still open: SPI's count may be a declared-mode figure rather than the
strict-complete measurement. The CSV's `swift_version` and `as_of` columns exist so the selection
is auditable once the data is in.

## 5. Stratum definitions as implemented

| Stratum | How it was built | Size | vs ROADMAP |
|---|---|---|---|
| `S-emit` | `census select emit` over supplied SPI data; tertile sample (head / middle / tail) | 0 until data arrives | target ~30 |
| `S-control` | `census select control`: seeded uniform draw from the pinned SPI PackageList (12,201 GitHub repos at the pinned commit), excluding archived/disabled repos and any with no push in 365 days; default-branch HEAD pinned to a SHA | 30 | target ~20; over-drawn because some will not build on Linux |
| `S-anchor` | named: swift-nio, swift-collections, swift-concurrency-extras, vapor | 4 | target ~5 |
| `S-byproduct` | LedgerKit's graph. LedgerKit has **one** dependency (GRDB.swift 7.11.1); LedgerKit itself is included as the root | 2 | target ~8: the graph is simply that small |

"SPI-active" in A3 is approximated by GitHub `pushed_at` within 365 days, because SPI's own
activity signal is behind the same challenge. The seed (`20261004`), the PackageList commit and the
draw position are recorded in each entry's `selection` field, so the draw is reproducible.
`SplitMix64` and the shuffle are implemented in-repo, with golden tests, because the standard
library's `shuffled(using:)` may change its algorithm between releases.

## 6. Measurement details that are not in the canonical invocation

The canonical invocation (CLAUDE.md) is used unchanged apart from non-semantic additions: `-v`
(resolved frontend command lines land in the log, per F7), `--cache-path /swiftpm-cache`, and
`-Xswiftc -module-cache-path /modcache`. The build system is each toolchain's SwiftPM default; it
is not pinned, and the resolved frontend invocation is recorded per cell.
