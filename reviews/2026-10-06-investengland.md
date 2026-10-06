<!-- reviewed at commit 58fbc761 on 2026-10-06 -->
# Review: InvestEngland (`sportsengland/InvestmentSystem`)

## Summary

A well-built grant management system with a genuinely good architecture: a thin
API over an isolated domain layer, tenancy enforced in the database rather than
in application code, and an integrations seam that swaps providers by
configuration. The code reads as the work of people who know what they are
doing.

Two defects undercut that. **(1)** Security gating keys off
`ENVIRONMENT == "production"`, while the codebase's own comments state three
times that Azure sets `ENVIRONMENT=live` — if true, five unauthenticated
`/.demo/*` endpoints are live in production, one of which force-authorises
payments and one of which mutates every tenant's funding configuration.
**(2)** All 12 database views bypass row-level security, confirmed by execution;
tenant isolation does not hold through them for either application role.

Neither is exotic. Both are one-line-ish fixes. The pattern behind them is the
same: a correct mechanism undermined by a gate that was never tested against
the value production actually uses.

Beneath those, the core entity tables have no primary keys and no indexes —
fine at demo scale, an outage at production scale — and tagged deploys are
configured to proceed with failing tests.

**Recommended next step:** confirm the live value of `ENVIRONMENT` and the
API's ingress exposure today (F1). Everything else can wait a week; that cannot.

---

## Severity scale

Per `.claude/rules/review-rubric.md`: **High** blocks change or risks outage,
**Medium** slows change, **Low** is hygiene. The rubric has no security axis —
it predates the survey and says so. I have added **Critical** for
unauthenticated access to financial mutation, and rated the isolation defects
against exposure rather than against velocity.

## Findings

| # | Area | Severity | Finding | Evidence | Status |
|---|---|---|---|---|---|
| F1 | Deploy / auth | **Critical** | `is_production()` is almost certainly false in deployed environments, exposing 5 unauthenticated `/.demo/*` endpoints and the API docs | `vendor/unrest/unrest/contexts/config.py:13-14`; `api/endpoints/demo.py:13`; `api/endpoints/__init__.py:195,202,239` | [verified] in code; deployment value [assumed] |
| F2 | Tenancy | **High** | All 12 views bypass RLS; isolation fails for both the BFF and the API roles | `sql/export/schema.sql` (12× `ALTER VIEW … OWNER TO admin`, 0 `security_invoker`, 0 `FORCE ROW LEVEL SECURITY`) | [verified by execution] |
| F3 | Build / deploy | **High** | Every `main.yml` run is tag-triggered, and the test step is `continue-on-error: true` for tags — so deploys proceed with failing tests | `.github/workflows/main.yml:24-33`; `demo.yml:24-28` | [verified] |
| F4 | Data model | **High** | 21 core tables have no primary key and no index on `id`; `application`, `organisation`, `project`, `project_payments` have no indexes at all | `sql/export/schema.sql` (37 PKs / 59 tables; 37 indexes, none on those tables) | [verified] |
| F5 | Finance | **High** | The ledger invariant check never runs outside tests, so a balance divergence would go undetected | `foundational/finance/ledger/__init__.py:303-311`; only callers are tests and a demo-gated endpoint | [verified] |
| F6 | Coupling | Medium | The DB schema is an uncontracted public interface of the frontend — 35 direct SQL sites, no compiler or contract catches a column rename | `frontend/foundational/*.ts` (15 modules import the SQL helper) | [verified] |
| F7 | Structure | Medium | Four genuine top-level import cycles inside `foundational`, all centred on `entities` | `entities/applications.py:6-7` ↔ `formal/attachments.py:3`; `infra/tickets.py:13` ↔ `entities/applications.py:15`; + `compliance`, `schema` | [verified] |
| F8 | Data / ops | Medium | `pgutil restore` runs `psql` without `ON_ERROR_STOP`, so a half-failed restore reports success | `sql/pgutil:274` (vs the commented-out `:273` and every other call site) | [verified] |
| F9 | Migrations | Medium | The migration generator emits `YYYYMMDDHHMM` while every existing file is low-sequential; the first date-stamped migration silently strands any later low-numbered file | `sql/pgutil:307` vs `migrations/` (`000000000000`–`000000000110`) | [verified] |
| F10 | Tenancy | Medium | 16 tables carry `tenant_id` with no RLS policy; several are defensible, the rest undocumented | `sql/export/schema.sql`; 41 of 59 tables policied | [verified]; intent [assumed] |
| F11 | Finance | Medium | `integer` pence on payment line items caps at £21,474,836.47, while the aggregate columns above them are `bigint` | `sql/export/schema.sql:535-541,306-308,1369` vs `:207,488` | [verified]; domain limit unknown |
| F12 | Data model | Medium | Application status has no DB constraint and no transition validation; the canonical list exists only in TypeScript. `ticket` by contrast has a validated state machine | `frontend/foundational/utils/application-status.ts:17-28`; `foundational/entity.py:79-90`; cf. `workspaces/tickets.py:8,148` | [verified] |
| F13 | Auth | Medium | `Permission.__call__` returns `True` unconditionally in development, so permission behaviour is never exercised locally | `foundational/authz.py:9-15`; also `api/endpoints/auth.py:46-47` | [verified] |
| F14 | Data model | Medium | All rich user data is stored as a Python `pickle` in `bytea` — opaque to SQL, coupled to the class graph, and a code-execution path for anyone with write access to that column | `foundational/formal/storage.py:87,108` | [verified] |
| F15 | Hygiene | Low | ~73 MB of generated data dumps committed to git, dominating the repo's line count | `sql/export/{data,demo/data,scenarios/data}.sql` | [verified] |
| F16 | Boundaries | Low | `grantseekers` imports from `grantmakers`, which is not a declared dependency; the symbol is a 3-line re-export | `grantseekers/app/routes/healthcheck.tsx:2` | [verified] |
| F17 | Boundaries | Low | BFF calls `POST /audit` directly, breaking the "all mutations via API" rule; `FIXME` and `TODO` on both sides | `api/endpoints/__init__.py:42-46`; `.server/modules.ts:48` | [verified] |
| F18 | Docs vs reality | Low | `export/schema.sql` is stale by one migration; `backend/app.py` is 0 bytes; README documents a `backend/scheduler` directory that does not exist | — | [verified] |
| F19 | Dead code | Low | Three views are referenced nowhere: `financial_planning`, `funding_revenue_candidates`, `programme_expense_candidates` | grep of both stacks | [verified]; ad-hoc analyst use [assumed] |

---

## F1 — `is_production()` is probably false in production

**Critical.** The highest-priority item in this review.

```python
def is_production() -> bool:
    return get("ENVIRONMENT") == "production"
```
(`vendor/unrest/unrest/contexts/config.py:13-14`)

Three comments in three different files state that this is not the value Azure
sets:

- `config.py:19-20` — "Azure often sets ENVIRONMENT=live for sit/uat/live"
- `foundational/authn.py:28-29` — "Azure often sets ENVIRONMENT=live on sit/uat
  **as well as live**"
- `frontend/foundational/.server/configuration.ts:49-50` — "ENVIRONMENT cannot
  be trusted here because Azure sets it to live on sit and uat too"

The team evidently knows: they introduced a separate `ARENA_TIER` variable and
`is_internal_tier()` specifically to work around it, and used that — not
`ENVIRONMENT` — to gate OTP bypass and the email whitelist. But `is_production()`
was left keyed to `ENVIRONMENT`, and two things still depend on it.

**Consequence if `ENVIRONMENT=live` in production:**

`api/endpoints/demo.py:13` is `if not config.is_production():` — so all five
endpoints inside register, each declared `auth.Unrestricted`:

| Endpoint | What it does |
|---|---|
| `/.demo/postcommit/{project_id}` | accepts the award, launches the project, then claims, accepts, approves, batches and **authorises payments with `force=True`** |
| `/.demo/accounts/rebalance` | rewrites every ledger account's cached balance |
| `/.demo/admin` | iterates **all tenants** under `systemcontext` (bypassing RLS by design) and mutates programme funding sources |
| `/.demo/seed-location`, `/.demo/seed-e2e-awarded` | seed fixture data |

And `api/endpoints/__init__.py:195,202,239` serve `/openapi.json`, `/docs` and
`/redoc` — a full API map.

**Why this was not caught.** There is a test, and it passes:
`test_api_docs_endpoints_return_404_in_production` sets
`monkeypatch.setenv("ENVIRONMENT", "production")` and asserts 404
(`api/tests/test_api_docs_endpoints.py:36-42`). It enshrines a value the
deployment apparently never uses, so it passes while the deployed behaviour is
the opposite. The literal string `"production"` appears as an `ENVIRONMENT`
value nowhere else in the repo; `test_email.py` uses `"demo"` and `"live"`.

**What I could not verify.** The `.env` files are git-crypt encrypted, so I
cannot read the live value, and there is no IaC in the repo to show the API
Container App's ingress. If the API is internal-only, exposure is limited to
anything already inside the network. The code-level defect — gating security on
a string the codebase elsewhere says is wrong — holds regardless.

**Recommended action.**
1. Today: read `ENVIRONMENT` and `ARENA_TIER` on the live API container, and
   check whether its ingress is external. If `ENVIRONMENT != "production"`,
   treat as an incident.
2. Invert the gate to fail closed — opt *in* to demo routes via an explicit
   `ARENA_TIER` allowlist, rather than opt out of production. Never register
   an `Unrestricted` route that mutates money on a negative check.
3. Rewrite the test to assert against the values deployments actually use
   (`live`, `dev`, `sit`, `uat`, `demo`), not `"production"`.

**Question for the team:** was `ENVIRONMENT=production` ever used, or has
`is_production()` been dead-false since the Azure migration?

## F2 — All 12 views bypass RLS

**High.** Verified by execution, not inference — repro at
`_workspace/verification/2026-10-06-rls-view-bypass.sh`, detail in
`docs/.../02-data-model.md` §3.1.

Views are owned by `admin`, which also owns the tables; no view sets
`security_invoker` and no table sets `FORCE ROW LEVEL SECURITY`. A
non-`security_invoker` view therefore reads as `admin`, and a table owner is
exempt from its own policies. Reproduced against the repo's own exported schema
in PostgreSQL 16.15, with a session scoped to one tenant:

| Connected as | `application` table | `project_payment_schedule` view |
|---|---|---|
| `queryuser` (`readonly_access`, the BFF) | 1 row | **2 rows** |
| `mutateuser` (`readwrite_access`, the API) | 1 row | **2 rows** |

The real BFF query (`frontend/foundational/funds.ts:486-496`) returned both
tenants' organisation names, payment references and amounts. 11 of the 12 views
read RLS-protected tables; three are nested, so a fix must be applied at each
level.

**Latent, not live** — one tenant row in the demo data, and the deployed tenant
count is unknown. This becomes Critical the day a second tenant is onboarded.

**Recommended action.** `ALTER VIEW … SET (security_invoker = true)` on all 12
(verified to fix it for both roles, with no over-blocking and no effect on the
owner). Do **not** use `FORCE ROW LEVEL SECURITY` — verified to break `admin`,
because the RLS helpers call `current_setting` without `missing_ok`. Add a
two-tenant regression test; there is currently none.

## F3 — Tagged deploys proceed with failing tests

**High.** `main.yml` triggers only on tags (`dev-*`, `uat-*`, `test-*`,
`live-*`). It has two test steps: one guarded `if: startsWith(github.ref,
'refs/tags/')` with `continue-on-error: true`, and one for non-tags without it.
Since every run is tag-triggered, only the `continue-on-error` branch ever
executes. `continue-on-error` fails the step but passes the job, so the
downstream `needs: [test]` + `if: success()` gates are satisfied and the deploy
proceeds. `demo.yml:24-28` does the same.

The release path to **live** therefore has no test gate. `test.yml` does run
properly on every branch push, so this is a gap in the release gate, not an
absence of CI.

**Recommended action.** Remove `continue-on-error` for `live-*` at minimum.
If tagged builds are flaky for environmental reasons, fix or quarantine those
tests rather than disabling the gate.

## F4 — No primary keys or indexes on the core tables

**High.** Postgres table inheritance carries columns only, not constraints or
indexes. 22 tables have no primary key; of those only `ledger_accounts`
recovers an index on `id` (via a unique constraint). `application`,
`organisation`, `project`, `project_payments`, `project_payment_line_items`,
`fund`, `programme` and `budget_line_item` have **no indexes at all**.

So `select * from application where id = $1` — the most common query shape in
the system — is a sequential scan, as is every join on `application_id`,
`organisation_id`, `audit_log.entity_id` and `ledger_entries.transaction_id`.

Invisible at demo scale (139 form rows, 368 audit rows). Not invisible later.
Migration 110 added the first index on `application`, so the fix is already in
the established house style.

**Recommended action.** Add `PRIMARY KEY (id)` to each `entity` descendant and
indexes on the FK-shaped columns. Measure first on a production-sized dataset
so the index set is evidence-led.

## F5 — The ledger invariant never runs

**High.** `assert_invariants()` checks global `sum(credit) = sum(debit)` and
every cached `_balance`, and raises a `LedgerPanic` whose declared action is
`lockdown`. Its only callers are `tests/test_ledger.py` and
`rebalance_accounts()`, which is reachable only from the demo endpoints. So the
detection mechanism exists, is tested, and is not armed in production — on a
system that moves public grant money.

Its own comment states the stakes: "if an account `_balance` ever diverges then
this will be a major error. However, there is no way to recover from it except
to recalculate all balances from scratch."

**Recommended action.** Run it on a schedule (there are already 13 cron tasks,
including a ledger-export failure alert) or after each `commit()`. Decide
deliberately whether `lockdown` is the right response in production.

---

## Strengths

Worth recording, because a findings list reads worse than the codebase is.

- **Tenancy in the database.** A two-attribute model applied by one helper
  generating four policies per table is the right call — it survives
  application bugs in a way application-level filtering does not. F2 is a flaw
  in the plumbing, not the design.
- **The integrations seam** (`01-architecture.md` §6). A `"domain:provider"`
  registry resolved per-tenant at runtime, where a config value starting with
  `http` transparently swaps in an HTTP proxy implementing the same interface.
  The domain layer imports no vendor SDK. 13 providers behind 9 interfaces.
- **A thin API over an isolated domain.** 2,042 lines of transport over 16,156
  of domain logic, and nothing in the domain imports the transport.
- **The newer subsystems are the better ones.** Tickets have a validated state
  machine and 11 indexes; the geo layer has partial indexes and a cache table.
  Standards are rising, not falling.
- **Honest comments.** `FIXME`s that name the right fix, a migration comment
  explaining why RLS must be reapplied per child, an inline note on why a
  pre-auth query bypasses tenant context, and a documented naming trap
  distinguishing `rejected` from `denied`. Several findings here were found
  *because* the authors wrote down what bothered them.
- **Deliberate use of sharp tools.** `application_urn_sequence` enables RLS with
  no policies — deny-all — and is reachable only through a `SECURITY DEFINER`
  function. That is someone who understands the mechanism.
- **Real test depth where it matters.** 57 Python test files covering payments,
  ledger, RLS, KYC and permissions; 21 Playwright specs across both portals.

## Assumptions

| # | Assumption | How to check |
|---|---|---|
| A1 | `ENVIRONMENT=live` (not `production`) in deployed environments | read the env on the live API container — **do this first** |
| A2 | The API Container App's ingress is external | Azure portal / `az containerapp show`; no IaC in repo |
| A3 | Only one tenant exists today, making F2 latent | `select count(*) from tenants` in each environment |
| A4 | Container Apps ingress replaces the Caddy gateway in deployment | gateway is not among the 7 pushed images; no IaC to confirm |
| A5 | `project.amount_awarded numeric` is a 360Giving reporting field, not operational | ask; it sits among the other 360Giving columns |
| A6 | The three unreferenced views are used ad hoc by analysts | ask; the README invites exactly this use |

## Notes

- **Where this reasoning is weakest:** F1's severity rests on A1, which I cannot
  verify from an encrypted clone. If `ENVIRONMENT` really is `"production"` in
  live, F1 drops to Medium (the three comments would then be about sit/uat only,
  and the gate would be correct but confusingly documented). I rated it Critical
  because the three comments are unambiguous and the downside is unauthenticated
  payment authorisation. **Confirming A1 is the single highest-value action
  available.**
- **Corrections made during the review.** F2 was initially written as a
  BFF-only problem; execution showed the API role is affected identically. I
  also claimed "all views" before `pg_depend` showed 11 of 12, and missed the
  three nested views entirely on the static pass. Earlier, I recorded two
  committed data dumps as duplicates on matching line counts — same byte size,
  different checksums, so regenerations. Counts in `01-architecture.md` were
  corrected against source after drafting (module count, permission count,
  inheritance clauses, SQL call sites).
- **Not yet reviewed:** `03-apis`, `04-dependencies`, `05-deployment`,
  `06-testing`. Dependency currency and licensing in particular are untouched,
  and the vendored `unrest` framework needs its own look — it is editable
  in-tree and unpinned from upstream.
- **Rubric fit.** The rubric's three severities are velocity-shaped and do not
  accommodate security exposure; I added Critical rather than force F1 into
  "High". Worth tuning the rubric now that the stack is known, as it invites.

## Changelog

| Date | Change | Why |
|---|---|---|
| 2026-10-06 | Initial review at `58fbc761` | First pass after survey, architecture and data-model docs |
| 2026-10-06 | F2 upgraded from inferred to verified-by-execution; scope corrected to include the API role | Reproduced in a throwaway PG16 container against the repo's own schema |
| 2026-10-06 | F1 added as Critical | Found while verifying the severity of the demo-endpoint exposure for this review |
| 2026-10-06 | De-duplicated `01`/`02` (02 now owns RLS coverage and DB principals); added four diagrams | Information-architecture pass: separate mechanism from coverage, make the inheritance consequences visual |
