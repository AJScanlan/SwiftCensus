---
name: adr
description: Draft a census ADR in docs/decisions/ in this project's house shape — a plain decision, a pre-registered gate or run (with its power statement and a sealed Results section), or a response to a result already seen. Use it whenever a decision is about to be recorded, a gate or threshold is being set before a run, a check has failed and needs investigating on the record, a ROADMAP amendment or SPEC change is proposed, or the owner says "write this up as an ADR" — and check the existing ADRs before re-deciding anything they already cover.
argument-hint: "[decision | pre-registered | response] <short title>"
---

# Census ADRs

ADRs are this project's memory of *why*. The rules about them come from what went wrong without them. A gate defined
after its data was seen can be bent to pass. A failed result that gets "clarified" stops being a failure. A gate that
can only observe a quarter of its population (G2, ADR 0009) passes or fails for reasons unrelated to its question.
Every part of the templates below exists to stop one of those.

## 1. Before writing

- **Read the existing ADRs first** (`ls docs/decisions/`, then the ones that touch this topic). If one already decides
  the question, the answer is to point at it, or to write a new ADR that amends it, never to decide it again silently.
- **Find what it amends**: a ROADMAP amendment (A1–A12), a footgun (F1–F7), a SPEC section, or an earlier ADR. ROADMAP
  §1 beats SPEC where they disagree.
- **Check CLAUDE.md's "Do not propose these" list.** An ADR is not a way around it.
- Number: the next free `NNNN` in `docs/decisions/`. File: `NNNN-<kebab-summary>.md`.

## 2. Pick the shape

| Situation | Template |
|---|---|
| A design or scope decision with no run attached (capture route, matrix, platform) | `templates/decision.md` |
| A gate, threshold, selection rule or run procedure that will judge data not yet produced | `templates/pre-registered.md` |
| A result has been seen (a gate failed, a check surprised) and needs investigating or answering | `templates/response.md` |

If a response also changes a rule for future runs, the new rule is pre-registered inside it (as ADR 0010 does), and
the old data is explicitly **not** re-scored under it.

## 3. Rules that make an ADR valid here

- **Status starts as `proposed`.** Only the owner accepts. Write `**accepted by the owner (<date>)**` only when they
  have said so in this session, and commit "(proposed)" ADRs as such (e.g. `ADR 0011 (proposed): …`).
- **Pre-registration is sealed at commit.** Everything above `## Results` is committed before the first cell of the
  runs it judges is built, and is not edited after results are seen. If it turns out to be wrong, a new ADR says so.
  The `guard-pinned.sh` hook asks before any edit above `## Results`. That prompt is the point, not an obstacle.
- **A gate states its power (ADR 0009 rule 5).** Give the share of the gate's population the gating measurement can
  observe, estimated from runs already committed (cite them and the counts), and a minimum below which the gate reports
  **underpowered** instead of pass or fail.
- **Every value a later reader could dispute is in the table.** That includes image digests, run ids, flags, the
  denominator, the threshold and its direction (`< 0.5 fails`, and what 15 of 30 does), what counts and what does not,
  and what happens on `infra_error` or a missing cell.
- **Say what it does not test.** A gate that passes is read as evidence of more than it checked unless the ADR says
  otherwise.
- **Known biases are named and counted**, with how the M3 write-up will report them.
- **A failed result stays failed.** A response ADR opens with "The result, which stands" and says what it does not
  change: no re-score, no moved threshold, no changed population.
- **Linux and macOS are never pooled (F6).** Linux never gates a stratum selected on macOS (ADR 0009).
- **Numbers are checked against run data.** Before committing, run the `numbers-auditor` agent on the draft.

## 4. Style

Match the existing ADRs: an em-dash title (`# ADR NNNN — <title>`, adding `(pre-registered)` where it applies), a bold
key/value header block, short declarative sentences, backticked identifiers, and commit hashes and run ids rather than
"the last run". Write decisions as numbered rules that can be cited ("ADR 0010 rule 3"). Leave out filler and hedging.
If something is unknown, write it under "Not verified" and do not soften the claim around it.

## 5. After drafting

1. Run `numbers-auditor` on the draft if it contains any number taken from runs.
2. Show the owner the draft and ask them to accept or amend it. Do not mark it accepted yourself.
3. Commit it alone (`ADR NNNN (proposed): <title>`). For a pre-registered ADR, commit it before any run it governs
   starts. Update `runs/README.md` and the ROADMAP pointers in a separate commit once it is accepted.
