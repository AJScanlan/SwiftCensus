# ADR NNNN — <Title> (pre-registered)

**Status:** proposed. Everything above "Results" is pre-registered: it is committed before the first cell of <the runs
it judges> is built and is not edited after results are seen. If it turns out to be wrong, a new ADR says so.
**Date:** YYYY-MM-DD
**Milestone:** M<n> (<area>)
**Operationalises:** <ADR NNNN D<n> / ROADMAP G<n>, A<n>> <!-- or Amends:, Responds to: -->
**Relates to:** <ADR NNNN, …; ROADMAP …>

## Context

<What question the runs answer and why now. Which committed runs the estimates below come from.>

## Decision

<One sentence: what is run, how many times, at which commit.>

| Item | Fixed value |
|---|---|
| Population | <exactly which entries or cells, at which commit of `corpus/packages.yaml`> |
| Denominator | <fixed number; whether any outcome drops an entry (normally: none)> |
| "Counts" | <the exact record filter: outcome, `attribution: primary`, `severity ≠ note`, mode `strict-complete-v5`> |
| Does not count | <every other outcome, by name> |
| `infra_error` / missing cell | <one retry by deleting the cell directory; if still missing, the gate is **not evaluated** and the report says why> |
| Gating column | <platform, toolchain, image @ digest, arch, which pass (first, never the re-run)> |
| Threshold | <`x / N < t` fails; state the boundary case, e.g. "15 of 30 passes"> |
| Reported, not gating | <other columns, tertiles, the any-outcome fraction> |
| Images / guest | <every image @ digest; guest restore digest and Xcode build. Nothing is pulled until the last run is committed> |
| Runs | <run ids (`<D>`, `<D>-rerun`, …) and their exact `census run` flags> |
| One tools commit | <`git diff <freeze> <run commit> -- tools corpus` empty for every run; no `tools_git_dirty: true`> |
| Pass condition | <the command and its required output, e.g. `census compare` SET-IDENTICAL for both pairs> |
| A failed check | Investigated. Not re-run until green. If an instrument bug is fixed, both passes of the affected pair are re-run at the fixed commit under new run ids |
| If the gate fails | <what happens next, and what does **not** happen without a new ADR (no re-selection, no moved threshold)> |

## Power (ADR 0009 rule 5)

<The share of the population the gating measurement can observe, estimated from committed runs: "<k> of <n> cells
(<p>%) on <run id>". The minimum below which this gate reports **underpowered** instead of pass or fail, and why that
minimum.>

## What this does and does not test

<What a pass establishes. What it does not, stated explicitly enough that a pass cannot be over-read.>

## Known biases

<Each bias this design introduces or inherits, with its size on committed runs and how the M3 write-up reports it.>

## Consequences

<What a pass unlocks; what a fail blocks; what does not depend on the outcome.>

## Results

Not yet run.

<!-- Filled after the runs, below this line only:
### Checks
### Outcomes per run
### <Gate>
### Recorded deviations
### Not verified
-->
