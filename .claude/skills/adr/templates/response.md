# ADR NNNN — <What happened>: <what this ADR does>

**Status:** proposed. Written **after** <the result> was seen. Nothing here is pre-registered, and nothing here changes
that result. <!-- If a rule for future runs is introduced below, add: "Rule <n> is pre-registered for <future runs>." -->
**Date:** YYYY-MM-DD
**Milestone:** M<n> (<area>)
**Responds to:** <ADR NNNN Results (<gate> <FAIL>); the rule that required this response>
**Relates to:** <ADR NNNN, …; ROADMAP …>

## The result, which stands

**<Gate/check> <failed>.** <The number, against the pre-registered threshold.> This ADR does not re-score <it>, does
not move its threshold, does not change its population, and does not call it a pass under another name.

## Why this ADR exists

<The obligation it discharges (e.g. "the selector is investigated before M2"), or the decision the result forces.>

## Context: the mechanism, diagnosed from committed bytes

<What was traced, from which committed files (`build.log.gz`, `dia.tar.gz`, `cell.json`), without re-running.
Separate what was proven ("traced task by task") from what is only consistent with it.>

## Findings

### 1. <Finding>

<Evidence with counts and run ids.>

## Conclusion

### What the investigation does not establish

## Decision

<Numbered rules. If one changes a rule for the future, it applies only to fresh runs, and the data that failed is
explicitly not re-evaluated under it as a substitute.>

## Power of any new check (ADR 0009 rule 5)

<Only if a rule above is a gate or check on future runs. Delete otherwise.>

## Known bias introduced

<Only if a rule above introduces one. Delete otherwise.>

## Consequences

<What the published record says about the failure. It is part of the record, not a footnote. What is still blocked
and by what.>

## Results

<Only if the ADR pre-registers fresh runs. "Not yet run." until then. Delete otherwise.>
