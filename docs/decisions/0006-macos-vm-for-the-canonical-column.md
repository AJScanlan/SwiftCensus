# ADR 0006 — A macOS VM for the canonical column; Linux keeps the cross-toolchain axis

**Status:** two-platform design **accepted by the owner (2026-10-10)**. Lima spike **succeeded**; the macOS cell runner is **built**, and a macOS run plus re-run is committed and set-identical (see "Implementation results"). Egress firewall added at the owner's request.
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

## Egress firewall (owner request, 2026-10-10)

The owner accepts LAN reachability on security grounds but prefers it blocked if it could affect results.
It can: results should not depend on where the machine sits. Measured on a clone before the policy, the
guest reached the LAN router (ports 80/443, ping) and ports on the host's own LAN address (e.g. 5000).

`tools/vm/pf.census.conf`, installed in the golden guest as a LaunchDaemon (`com.census.pf`), blocks
**new** TCP connections (SYN only), and all UDP and ICMP, to the host's NAT address (192.168.5.1) and to
every private range (10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10), except the Lima NAT subnet
192.168.5.0/24 (gateway and DNS are 192.168.5.2). The internet is untouched. Verified: LAN, router (incl.
ping), host services, `10.x` and `172.16.x` unreachable; `github.com` 200, `download.swift.org` 302.

Two things went wrong on the way, both worth keeping:

- **Blocking every packet to 192.168.5.1 hangs the instance.** pf loads after Lima's SSH ControlMaster is
  already connected; the connection's replies have no pf state and were dropped. Blocking only SYNs fixes it.
- **A race.** The daemon loads after SSH is up, so an early test wrongly reported the LAN open.
  `GuestVM.create()` now waits for the rules and checks behaviour (the NAT host must not answer ping) and
  refuses to build otherwise.

This is **not a security boundary**: the guest user can read `~/password` and `sudo`. It protects result
integrity, which is what was asked. It assumes the Lima NAT subnet does not collide with the owner's LAN
(here 192.168.68.0/24).

## Implementation results (2026-10-10)

`census run --platform macos` clones the golden guest, waits for SSH and the firewall, builds each cell in a
fresh directory, copies results out, and deletes the clone. It shares `CellIngest`, the parser and the
classifier with the Linux runner. macOS has **one** toolchain column, `xcode-27.0`, and a macOS run never
shares a run id with a Linux run (F6). All 36 corpus entries now list `macos-spm`.

| Run | Cells | Outcomes | A7 |
|---|---|---|---|
| `2026-10-10-macos` | 39 | 33 built, 6 build_failed | — |
| `2026-10-10-macos-rerun` | 39 | identical | **SET-IDENTICAL** over 39 cells |

- **Coverage.** `S-control` built 20 of 29 on macOS against 12 of 29 on Linux 6.4, and 8 of the 20 emit
  (Linux: 4 of 12). Every `S-anchor` and `S-byproduct` cell built.
- **`S-byproduct`.** LedgerKit: 0 diagnostics. GRDB built as its own root: 8 primary warnings. LedgerKit's own
  build shows 0 *transitive* because SwiftPM suppresses warnings in dependencies, so a root's
  `transitive` bucket only ever holds errors, and a dependency's diagnostics are measured by building it as a root.
- **F6 confirmed.** Of 16 packages that built on both macOS and Linux 6.4, 3 differ in warning count
  (swift-nio 206 vs 205, SwiftSMB 26 vs 0, SSTV-MEL 1 vs 4): different source compiles per platform.
- **Declared mode.** For `swift-concurrency-extras` (tools-version 6), `strict-complete-declared` reports
  0 warnings against 3 under `strict-complete-v5`: ADR 0002's censoring, reproduced on macOS.

**Memory.** The host has 16 GiB. The guest is 10 GiB / 8 CPUs; with Docker Desktop's 7.75 GiB VM also running,
swap reached 4 of 5 GB and first boots of clones stalled at "boot scripts must have finished". Docker Desktop
must be **quit during a macOS run**. The two platforms run one after the other.

**Classifier fix found on macOS.** `unable to resolve module dependency: 'UIKit'` matched the loose
`unable to resolve` marker, so three iOS-only packages were filed as `resolve_failed`. The marker was removed
and `census reclassify` added: it re-derives outcomes from the committed `build.log.gz` without a rebuild
(the reason raw logs are committed). Dry-run over both Linux runs: 0 changes. Both macOS runs: 3 cells fixed.

**Still unverified.** Behaviour over many more cells in one clone (disk growth); a package that builds a plugin
or macro on macOS; Apple's licence terms for macOS guests; whether Lima's "experimental" label shows as
flakiness over a larger run. The golden image is stopped; the restore image remains cached (26.6 GB).

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

## Decisions still open

1. The cached restore image (26.6 GB): the owner said to leave it unless space is needed.
2. Whether `S-emit` is selected from SPI data or by a macOS self-screen (ADR 0004 §4); the macOS runner makes
   the screen cheaper and unbiased against Apple-framework packages.
