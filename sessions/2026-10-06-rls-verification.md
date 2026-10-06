<!-- reviewed at commit 58fbc761 on 2026-10-06 -->
# Session: verifying the RLS view-bypass claim

## Why
`02-data-model.md` §3.1 asserted that the 12 admin-owned views bypass RLS, on
the strength of documented PostgreSQL semantics plus three verified schema
facts. It was the highest-stakes claim in the review and the only one resting on
inference rather than observation. Verifying it before assigning a severity.

## Method
Loaded the repo's own `backend/sql/export/schema.sql` into a throwaway
`postgres:16` container, replicating `pgutil`'s role topology, then seeded two
tenants and queried as the real application roles.

Repro script: `verification/2026-10-06-rls-view-bypass.sh`.

The one detail that makes the test valid: `admin` was created **without**
`SUPERUSER`, matching `pgutil:107` where `SUPERUSER` is commented out. A
superuser bypasses RLS unconditionally and would have proved nothing.

## Result: CONFIRMED
Session scoped to tenant A, via the same two `set_config` calls the BFF makes:

| Connected as | `application` table | `project_payment_schedule` view |
|---|---|---|
| `queryuser` (readonly_access) | 1 row | 2 rows |
| `mutateuser` (readwrite_access) | 1 row | 2 rows |

The real BFF query from `funds.ts:486` returned both tenants' organisation
names, payment references and amounts.

Loading the real schema also independently reproduced the static counts:
59 tables, 12 views, 164 policies, 41 RLS-enabled tables.

## Corrections to the earlier write-up
1. **Scope was wrong.** I had framed this as a BFF-only problem. The API's
   `readwrite_access` role is affected identically — it is also not the table
   owner. `entity_owners` returned 10 rows to a tenant-scoped `mutateuser`
   session versus 1 from the table. Every view consumer is affected.
2. **11 of 12 views affected, not "the views" generally.**
   `entity_location_details` is clean, but only because every table it reads is
   itself outside RLS — unaffected by accident, not design.
3. **Three views are nested**, so a fix must be applied at each level:
   `export_360_giving` → `entity_location_details`; `funding_revenue_candidates`
   and `programme_expense_candidates` → `programme_funding_candidates`. I had
   not spotted this statically.

## Fix, also verified
`security_invoker = true` on all 12 views closes it for both roles with no
over-blocking; the owner (migrations, `pg_dump`) is unaffected.

`FORCE ROW LEVEL SECURITY` also closes it but **breaks the owner** — `admin`
then fails with `unrecognized configuration parameter "rls.owner"`, because
`session_owner_id()` calls `current_setting` without `missing_ok`
(`rls.sql:19,23`). Good fail-closed property in the request path; rules FORCE
out as the remedy. Recommend `security_invoker`.

## Incidental findings
- The live function catalog lacks `next_application_urn`, independently
  confirming `export/schema.sql` is stale by migration 110 (§ data-model intro).
- The RLS helpers are fail-closed on a missing session variable. Worth keeping.

## Housekeeping
Docker Desktop was not running and had to be started; it crashed twice on
launch before stabilising on the third attempt. Container removed afterwards;
`git status` in the clone confirmed clean — the repo was never written to.

## Re-run (same day, after Docker Desktop was restarted)
Re-ran `verification/2026-10-06-rls-view-bypass.sh` from a clean container.
Reproduced identically: premises `views=12 security_invoker=0 force_rls=0
owners=admin`; 1 row from the table vs 2 through the view for both
`queryuser` and `mutateuser`; `security_invoker` fixes it for both; owner
unaffected. Nothing was lost by the shutdown — the container is torn down at
the end of each run by design, so the script is the artifact, not the container.

Two cosmetic defects in the script found and fixed on the re-run:
- `\$U` was escaped inside a quoted echo, so the two role blocks printed
  identical headers and were indistinguishable.
- The LEAKED query had no `ORDER BY`, so row order varied between runs.
Both fixed; re-run confirms self-labelling, deterministic output.
