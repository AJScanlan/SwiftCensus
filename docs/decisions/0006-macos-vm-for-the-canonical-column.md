# ADR 0006 — A macOS VM for the canonical column; Linux keeps the cross-toolchain axis

**Status:** two-platform design **accepted by the owner (2026-10-10)**. Lima spike **succeeded** (see "Spike results"); the macOS cell runner is not built yet.
**Date:** 2026-10-10
**Milestone:** M1
**Amends:** ADR 0004 §1–§2 (macOS cells "do not run in M1"; M1 "measures linux-spm only"); ADR 0003 (option B discouraged, option A adopted for Linux)
**Relates to:** ROADMAP A12, F3, F4, F6, F7; ADR 0004 §4–§5 (S-emit, S-byproduct)

## Context

ADR 0004 ran M1 on Linux only, because F3 forbids building third-party code on a machine holding
signing keys or personal data, and the only macOS machine is the owner's development machine. That
was an expedient, not the design: A12 makes macOS canonical for the headline distribution, and ADR
0003 already described the split (macOS: one current toolchain, breadth across Apple-SDK packages;
Linux: the multi-toolchain matrix).

The Linux-only run has two costs beyond the missing column:

- **Frame bias.** 17 of 29 `S-control` packages failed on Linux on 6.4, mostly because they need
  Apple frameworks (`SwiftUI`, `UIKit`, `.xcframework` binaries). Those are the UI and `@MainActor`
  packages whose diagnostics probably differ most. A Linux-only sample reports that population as
  absent, and a Linux-only screen for `S-emit` (ADR 0004 §4, fallback) would inherit the same bias.
- **`S-byproduct` cannot run.** LedgerKit imports `FoundationModels`; GRDB needs system SQLite
  headers the Linux image lacks.

A VM satisfies F3 if it holds no keys or personal data. It does not fix toolchain/SDK coupling
(ADR 0003): each toolchain on macOS still needs a compatible Xcode and SDK.

## Proposal

**Two platforms, each doing what it is good at.**

| Platform | Toolchains | Role |
|---|---|---|
| `macos-spm` in a VM | Xcode 27's Swift 6.4, plus whichever standalone toolchains run against its SDK (6.3.3 and nightly did in ADR 0003; 6.1 and 6.2 did not) | Canonical for the headline distribution (A12); Apple-SDK packages; `S-byproduct`; the `S-emit` screen if option 4 is taken |
| `linux-spm` in containers | 6.1, 6.2, 6.3, 6.4, nightly | Cross-toolchain axis, drift detection, nightly early warning, reproduction path |

Counts are aggregated per platform and never summed (F6).

## What is already on this machine

Surveyed 2026-10-10; no VM was created.

| Item | State |
|---|---|
| Host | Apple silicon, macOS 27.0, 16 GiB RAM, hypervisor support present, 129 GB free |
| Docker Desktop | Installed; its VM has 7.75 GiB. 19 images use 49.8 GB, 40.4 GB of it reclaimable |
| **Lima 2.1.1** | **Installed.** Ships `macos`, `macos-15` and `macos-26` templates; `vz` is its only VM type for macOS guests |
| UTM, Tart, Parallels, VMware, VirtualBox | Not installed. UTM is available as a Homebrew cask (4.7.5). Tart is not in Homebrew core |
| Xcode 27.0 | `/Applications/Xcode-27.0.0.app` on the host, 3.6 GB on disk |

**Lima is the lowest-friction option** because it is already installed and the owner already uses
it for a Linux VM. Its `macos-26` template downloads Apple's `UniversalMac_26.4_25E246` restore
image, digest-pinned, from `updates.cdn-apple.com`. UTM or a hand-rolled `Virtualization.framework`
setup would work too and are not ruled out.

## F3 requirements for the guest

The Lima template **does not meet F3 as shipped.** `_default/mounts.yaml` mounts the host's home
directory `~` into the guest, which would give third-party build code read access to the owner's
home. A usable setup must, before any corpus package is built:

1. Override the mounts to none. Move source and results by `scp`/`ssh` stream, as the Linux runner
   already moves them with `docker cp`.
2. Sign in to no Apple ID or iCloud account, and import no certificates or keychain items.
3. Use NAT networking and expose no host services to the guest.
4. Install Xcode into the guest by copying the app from the host, not by signing in to download it.
5. Take a snapshot of the clean golden image and restore it between runs.

Isolation is **per run, not per cell**: restoring a snapshot per cell would dominate the cost.
Within a run, a malicious package could affect later cells (F4's clean-tree rule still holds
because each cell builds in a fresh directory). F3 as written does not forbid this; it is recorded
here so the published number carries the caveat.

## Spike results (2026-10-10)

Lima 2.1.1, `vz`, template `tools/vm/census-macos.yaml` (no mounts). Lima labels non-Linux guests
**experimental**; `limactl snapshot` is `unimplemented` for them.

| Question | Result |
|---|---|
| Guest OS | macOS **27.0.1 (26A434)**, Apple's only public catalog image. The host is 27.0 (26A428); Virtualization.framework accepted a guest newer than its host. The owner reports Xcode 27 needs macOS ≥ 26.6, so Lima's 26.4 template could not have worked |
| Image integrity | 26,637,307,067 bytes; SHA-1 matches the catalog's `7e020710…`; SHA-256 `2f016638…` pinned in the template |
| Xcode | Host's `Xcode-27.0.0.app` copied over SSH (`limactl copy`, 4m24s); no Apple ID. `xcodebuild -license accept` and `-runFirstLaunch` succeed. Xcode 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1), target `arm64-apple-macosx27.0.0` |
| SSH | Works non-interactively through `limactl shell` / `limactl copy` |
| F3 isolation | Guest sees none of the host's home (`/Users/aj` absent; its own home is `/Users/aj.guest`). No iCloud/MobileMe account, 0 code-signing identities, only the system keychain, `sudo` requires a password. NAT address `192.168.5.15` |
| Build | `swift build` with the canonical flags plus `-serialize-diagnostics`: **Yams 5.4.0**, exit 0, 23 s, 39 `.dia`, 45 warnings / 133 notes. These are **identical to the Linux 6.4 cell** for the same SHA. They differ from `samples/m0.json` (48 / 91), which was built on Xcode 27 beta 6 (swiftlang-6.4.0.33.1); the difference was not investigated |
| `S-byproduct` | **LedgerKit** (root) builds on macOS: exit 0, 31 s, 215 `.dia`, **0 primary and 0 transitive diagnostics** (GRDB included). On Linux it could not build |
| Per-run restore | `limactl snapshot` unavailable. **`limactl clone` works**: 0.03 s, APFS copy-on-write, the clone boots in 16 s with Xcode intact |
| Resources | Instance 37 GB; cached IPSW 26.6 GB (deletable, but re-download needed to recreate); 6 CPUs, 6 GiB RAM, 100 GiB sparse disk |

**Per-run procedure:** keep `census-macos` as the stopped golden instance (Xcode installed, no
corpus, no builds); for each run `limactl clone census-macos census-<run-id>`, run all macOS cells in
it, copy results out, `limactl delete`. Parsing happens on the host (`census parse` was added for
this: it reads a `.dia` tarball and a package root).

**Not verified:** whether the NAT network can reach the host's LAN (F3 says nothing about the
network, but it is the remaining exposure); behaviour with a package that builds a plugin or macro
on macOS; behaviour across many cells in one clone (disk growth); Apple's licence terms for
macOS guests; whether Lima's "experimental" label shows up as flakiness over a full run.

## Tool choice

**Lima, as trialled.** Chosen because it is installed, its macOS guests use `vz` (the only supported type),
and it has `create`, `start`, `shell`, `copy`, `clone` and `snapshot` subcommands, so the runner can
script it. Move to **Tart** if a full run shows friction: it is built for disposable macOS CI guests
(OCI images, instant APFS clones), but it needs a tap install and its prebuilt images come from a
third party, which F3 argues against trusting. **UTM** is GUI-first and the weakest fit for a
scripted runner. Whether `snapshot` works for `vz` guests is unverified; `clone` of a golden
instance (an APFS copy) is the fallback for per-run restore.

## Consequences if accepted

- **A runner abstraction.** `CellRunner` is Docker-specific. A macOS runner (`ssh` in, copy source,
  `swift build` with the same canonical flags, copy the `.dia` tree back) sits beside it, behind a
  small platform protocol. The record schema, parser, attribution, and A7 comparison are unchanged.
  `Platform.macosSPM` already exists. Estimated effort: about a day, plus VM setup.
- **F7 additions.** Each macOS cell records the guest macOS build, the Xcode build number, the SDK,
  and the target triple.
- **`S-byproduct`** can run. **`S-control`** Apple-only entries become measurable rather than
  failed cells.
- **Option 4 (self-screened `S-emit`)** should screen on macOS, giving a higher yield than the 14%
  seen on Linux and removing the Linux frame bias. The count definition must still be fixed before
  results are looked at, and ADR 0004 §4 still needs the owner's choice between waiting for SPI
  data and screening.
- **M1's exit** would need both platforms' runs to be set-identical on re-run (A7), and ADR 0005
  (6.1 identifiers) remains open independently.
- **A12's "canonical column must be GA"** is still an M3 question. Xcode 27.0 reports no beta
  suffix, but whether it is GA is unconfirmed.

## Alternatives

- **Stay Linux-only.** Cheapest. Keeps the frame bias and leaves `S-byproduct` unmeasured; the M3
  report would have to state both as limitations.
- **A separate physical Mac or hosted runner.** Cleaner isolation than a VM, and no memory contention
  with Docker. Costs money or hardware the owner has not mentioned.
- **Multiple Xcodes for a macOS matrix.** Rejected in ADR 0003: the SDK would vary with the toolchain
  and a diagnostic change could not be attributed to the compiler.

## Decision still needed

1. Build the macOS cell runner (an `ssh`-driven sibling of `CellRunner`), then a macOS run and re-run?
2. Delete the cached IPSW (26.6 GB) to reclaim disk, or keep it so the guest can be recreated?
3. Is a NAT guest with LAN reachability acceptable, or should the guest be firewalled from the LAN?
