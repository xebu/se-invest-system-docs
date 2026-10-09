# Sport England Investment System — review

Independent review and reference documentation for the Sport England
Investment System (repo `sportsengland/InvestmentSystem`, codename **Arena**),
carried out October 2026 against commit `58fbc761`.

**This repository does not contain the system's source code.** It contains
documentation about it, and the findings of a read-only review. Nothing here
was ever committed to the client's repository.

## Start here

1. **[`reviews/2026-10-06-investengland.md`](reviews/2026-10-06-investengland.md)**
   — a standalone summary and 34 severity-rated findings, each with evidence,
   consequence and a recommended action. If you read one file, read this.
2. The reference docs below, for the evidence behind any individual finding.

## Contents

| Path | What it is |
|---|---|
| `reviews/` | The findings. One living file, revised in place. |
| `docs/sportsengland/InvestEngland/` | Reference docs 00–06: architecture, data model, interfaces, dependencies, deployment, testing. |
| `verification/` | Executable reproductions for findings proven by execution, not inference. |
| `sessions/` | Working notes — method, corrections made mid-review, what was checked and how. |
| [`diagrams/`](diagrams/) | Architecture views (request/data flow, tenant/auth/RLS) plus a written summary, **generated from the docs rather than the code** — with an accuracy check against the codebase. |

Current state: **1 Critical, 8 High, 17 Medium, 8 Low.**

### A note on the diagrams

`diagrams/` holds architecture views produced by a model reading the reference
docs — not the codebase. Two of the three are accurate; the third has a
fabricated identity provider and the wrong RLS variable names, because the
generating model filled gaps with conventional answers. Each is checked against
the code in [`diagrams/README.md`](diagrams/README.md), and the discrepancies
are documented rather than quietly corrected, since they show precisely where
generated documentation drifts. Read that file before quoting a diagram.

## Conventions

- Every claim is labelled **`[verified]`** (read in the code at `58fbc761`) or
  **`[assumed]`** (inferred, with the check that would settle it). Where intent
  could not be established from code, it is written up as a question for the
  team rather than asserted.
- Findings are referenced by ID (`F1`, `F2`, …) across all documents.
- Each doc is pinned to the commit it was written against, in an HTML comment
  at the top. The system has moved on since; treat everything as a snapshot.

## Relationship to the team's own documentation

The repository already contains ~2,800 lines of good internal documentation —
`ONBOARDING.md`, `BFF-INTEGRATION.md`, `INTEGRATIONS.md`, `ERRORS.md`. **Those
remain the reference for how the system works.** The docs here were written to
support a review, so they are forensic rather than explanatory: counts, line
numbers and assessments. They are not a replacement, and where the two
disagree, the client's docs describe the intent and these describe what the
code was verified to do.

## Handling

Some findings describe **unremediated** security defects, and `verification/`
contains a working reproduction of one of them. Treat this repository as
confidential until those are closed. One finding quotes a live credential that
is already exposed in the client's own repository; it should be redacted before
this material is circulated further.

## Open questions

Two findings cannot be rated without access this review did not have:

- **F1** — the value of `ENVIRONMENT` in deployed environments. If it is `live`
  rather than `production`, five unauthenticated endpoints are registered in
  production, one of which authorises payments.
- **F34** — whether PTX is the live payment provider, and whether its payment
  profile supplies the reference that the code omits.

Both need someone with Azure and provider-console access.
