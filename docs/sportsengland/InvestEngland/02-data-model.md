<!-- reviewed at commit 58fbc761 on 2026-10-06 -->
# InvestEngland — data model

Scope: schema shape and ownership, the inheritance model, migrations, integrity
enforcement, and shared mutable state. Tenancy *mechanism* is covered in
`01-architecture.md` §4; this doc covers where that mechanism does and does not
reach. Claims are `[verified]` (read in code/schema at `58fbc761`) or
`[assumed]`.

Two sources were used and they disagree slightly: the 19 hand-written
migrations under `backend/sql/migrations/`, and the generated snapshot
`backend/sql/export/schema.sql` (4,714 lines, produced by `pg_dump
--schema-only`). The snapshot is **behind the migrations by exactly one**
— it lacks `application_urn_sequence` from migration 110 [verified by
set-differencing every `create table` in both]. Otherwise they agree. Counts
below are from the snapshot unless stated.

---

## 1. Inventory

| Object | Count |
|---|---|
| Tables | 59 (+1 in migrations, not yet exported) |
| Views | 12 |
| Indexes | 37 |
| Primary keys | 37 |
| Foreign keys | **1** |
| CHECK constraints | **2** |
| Triggers | **0** |
| RLS policies | 164 (41 tables × 4) |
| Functions | 5 |
| `jsonb` columns | 23 |

The single foreign key is
`ticket_roles.organisation_role_id → organisation_roles(id) ON DELETE CASCADE`
(`export/schema.sql:2714-2715`) [verified]. The two CHECK constraints are both
on ledger tables — `ledger_accounts.type` and `ledger_transactions.expenditure`
(`:1131`, `:1191`) [verified].

**Referential and domain integrity is therefore almost entirely application-
enforced.** There is no database-level guarantee that
`application.organisation_id` points at an existing organisation, that a
`project_payment_line_items` row belongs to a live payment, or that
`entity.status` holds a recognised value.

## 2. The inheritance model

Two abstract base tables [verified: `migrations/000000000000__rls.sql:199-221`]:

```sql
CREATE TABLE owned (            -- the tenancy carrier
    tenant_id uuid not null,
    owner_id  uuid not null
);

CREATE TABLE entity (           -- a discrete business object
    id uuid default uuid_generate_v4() not null primary key,
    created_at timestamp not null default (now() at time zone 'UTC'),
    updated_at timestamp not null default (now() at time zone 'UTC'),
    deleted_at timestamp,
    name text,
    status text,
    metadata jsonb
) INHERITS (owned);
```

```
       ┌──────────────────────────────────────┐
       │ owned                                │  tenant_id, owner_id
       └──────────────────┬───────────────────┘  (the tenancy carrier)
                          │
           INHERITS (27)  │
        ┌─────────────────┴──────────────────┐
        │                                    │
        ▼                                    ▼
 ┌─────────────────────────┐      satellite tables — tenancy
 │ entity                  │      but not identity:
 │ id (PK), created_at,    │        membership, audit_log,
 │ updated_at, deleted_at, │        entity_status_changes,
 │ name, status, metadata  │        budget_line_item, ledger_*,
 └────────────┬────────────┘        formal_*
              │
 INHERITS (14)│
              ▼
 the business nouns — application, organisation, project, fund,
 programme, file_uploads, project_payments, bank_accounts, …


  CARRIED BY INHERITANCE      NOT CARRIED
  ──────────────────────      ────────────────────────────────────────────
  columns                     PRIMARY KEY  → 22 tables have none      (F4)
                              indexes      → none on the core tables  (F4)
                              RLS policies → helper re-run per child:
                                             164 policies instead of 8
                              FOREIGN KEY  → 1 in the entire schema
                              CHECK        → 2 in the entire schema
```

41 inheritance clauses across the migrations — 14 from `entity`, 27 from
`owned` [verified]. `entity` descendants are the business nouns (`application`,
`organisation`, `project`, `fund`, `programme`, `file_uploads`,
`project_payments`, …); `owned` descendants are the join/satellite tables that
need tenancy but not identity (`membership`, `audit_log`,
`entity_status_changes`, `budget_line_item`, the ledger tables, the formal
tables).

This buys real uniformity: `select ... from entity` reaches every business
object at once, and `(e.tableoid)::regclass` recovers the concrete type — used
in the `inferred_assignments` view (`export/schema.sql:1086`) [verified].

### 2.1 What inheritance does not carry

Postgres table inheritance propagates **columns only**. Constraints, indexes,
primary keys and RLS policies do not descend. The schema pays for this three
times.

**(a) RLS must be re-applied per child.** The migration says so in a comment:
"Annoyingly, we have to apply policies on the child tables"
(`000000000000__rls.sql:221`) [verified]. Hence 164 policies rather than 8.

**(b) 22 tables have no primary key** [verified by diffing every table against
every `PRIMARY KEY` constraint in the snapshot]:

`application`, `organisation`, `project`, `project_payments`,
`project_payment_line_items`, `project_payment_instructions`,
`project_award_conditions`, `bank_accounts`, `fund`, `programme`,
`budget_line_item`, `budget_line_item_project_year`, `entity_status_changes`,
`file_uploads`, `ledger_accounts`, `ledger_exports`,
`organisation_role_permissions`, `ticket`, `stripe_events`, `user_roles`,
`user_login_errors`, and the `owned` base table.

Of these, only `ledger_accounts` recovers an index on `id`, via
`UNIQUE (tenant_id, id)` (`:2235`). `user_roles` has `UNIQUE (user_id, role)`
and `organisation_role_permissions` has a composite unique, neither covering
`id`. **The remaining core entity tables have no unique constraint and no index
on `id` at all** [verified].

**(c) No indexes on the core tables.** Of the 37 indexes, zero are on
`application`, `organisation`, `project`, `project_payments`,
`project_payment_line_items`, `budget_line_item`, `fund`, or `programme`
[verified by grepping every `CREATE INDEX ... ON public.<table>`]. `ticket` has
three, none on `id`. The index set is concentrated on the newer subsystems —
tickets (11), geo/locations (8), formal (4), notifications (2).

So `select * from application where id = $1` — the single most common query
shape in the system — is a sequential scan, as is every join on
`application_id`, `organisation_id`, `project_id`, `audit_log.entity_id`,
`entity_status_changes.entity_id`, `ledger_entries.transaction_id`, and
`ledger_entries.account_id`.

This is invisible today. The demo dataset is tiny: 139 `formal_data` rows, 368
`audit_log` rows, 116 `project_payment_line_items`, 90
`entity_status_changes` [verified by counting `COPY` blocks in
`export/demo/data.sql`]. It will not stay invisible. Migration 110 did add the
first index on `application` — `UNIQUE (tenant_id, reference_number) WHERE
reference_number IS NOT NULL` — so the pattern is reparable in the established
style.

## 3. Where RLS reaches — and two places it does not

41 of 59 tables carry the four generated policies. The 18 without
[verified from the snapshot]:

`api_calls`, `email_attachments`, `entity_locations`, `geo_cache`,
`idv_persons`, `idv_sessions`, `informationrequest_notification_queue`,
`locations`, `owned`, `sent_emails`, `stripe_customers`, `stripe_events`,
`stripe_objects`, `tenants`, `user_login_errors`, `user_logins`, `user_roles`,
`users`.

All but `users` and the abstract `owned` carry a `tenant_id` column
[verified individually]. Several are defensible: `tenants` is the tenant
registry, `locations`/`geo_cache` are shared reference and cache data,
`user_logins`/`user_login_errors` are written before a tenant session exists,
and `idv_persons`/`idv_sessions` are read from a public pre-auth route — which
the BFF documents inline at `frontend/foundational/authn.ts:66-67,77-78`
[verified]. That inline note is the single best piece of evidence that the
exclusions are at least partly deliberate.

The rest — `stripe_customers`, `stripe_events`, `stripe_objects`,
`sent_emails`, `email_attachments`, `api_calls`, `user_roles`,
`informationrequest_notification_queue`, `entity_locations` — carry tenant data
with no policy, and nothing in the repo says why. `user_roles` is the one to ask
about first: it is how permissions are assigned.

A third pattern is worth naming because it is *good*:
`application_urn_sequence` enables RLS and deliberately defines **no**
policies, with the comment "no policies: only reachable through
next_application_urn", and is written solely by a `SECURITY DEFINER` function
(`migrations/000000000110__application_urn_sequence.sql:9-10`) [verified].
RLS-on-with-no-policy is deny-all, so that table is sealed except through its
function. That is a deliberate, correct use of the mechanism.

### 3.1 The views bypass RLS — verified by execution

**This is confirmed, not inferred.** It was reproduced on 2026-10-06 against
the repo's own `export/schema.sql` loaded into a throwaway PostgreSQL 16.15
container. The repro script is checked in at
`_workspace/verification/2026-10-06-rls-view-bypass.sh` and runs end-to-end from
a clean state. It touches nothing in the repo.

The setup mirrors `pgutil` exactly, including the detail that makes the test
valid: **`admin` is not a superuser** upstream — `SUPERUSER` is commented out at
`pgutil:107` — because a superuser would bypass RLS for an unrelated reason and
prove nothing.

Three premises, each confirmed live against the loaded schema rather than by
grep:

```
views=12   security_invoker=0   force_rls=0   owners=admin
```

All 12 views and all 59 tables have the single owner `admin`; no view sets
`security_invoker`; no table sets `FORCE ROW LEVEL SECURITY`. The loaded schema
also reproduced the static counts exactly — 59 tables, 12 views, 164 policies,
41 RLS-enabled tables.

**The result.** Two tenants were seeded through `project_payment_schedule`'s
full seven-table join chain. A session was then scoped to tenant A with the same
two `set_config` calls the BFF issues (`frontend/foundational/.server/db.ts:25-26`):

| Connected as | Direct table (`application`) | Via view (`project_payment_schedule`) |
|---|---|---|
| `queryuser` (`readonly_access`, the BFF) | **1 row** | **2 rows** |
| `mutateuser` (`readwrite_access`, the API) | **1 row** | **2 rows** |

Running the real BFF query verbatim — `select … from project_payment_schedule
where status = 'approved'` (`frontend/foundational/funds.ts:486-496`) — returned
both tenants' rows, exposing the other tenant's organisation name, payment
reference and amount:

```
 organisation_name | reference |  status
-------------------+-----------+----------
 Org a             | PAYREF-a  | approved
 Org b             | PAYREF-b  | approved
```

RLS works correctly on direct table access and does not apply through the views.

**Correction to my earlier scope.** I previously framed this as a BFF problem.
It is not: the API's `readwrite_access` role is affected identically, because it
is also not the table owner. `entity_owners` returned 10 rows to a tenant-scoped
`mutateuser` session against 1 from the table. Every consumer of these views is
affected, not just the read path.

**Blast radius.** 11 of the 12 views read at least one RLS-protected table
[verified via `pg_depend`]:

| View | RLS tables read |
|---|---|
| `project_payment_schedule` | 9 |
| `entity_owners` | 6 |
| `programme_funding_allocations` | 5 |
| `programme_funding_candidates` | 5 |
| `financial_planning` | 4 |
| `inferred_assignments` | 4 |
| `user_organisational_roles_summary` | 2 |
| `user_roles_derived` | 2 |
| `export_360_giving` | 1 |
| `funding_revenue_candidates` | 1 |
| `programme_expense_candidates` | 1 |

Only `entity_location_details` is clean, and only because every table it reads
(`entity_locations`, `locations`, `geo_cache`) is itself outside RLS — which is
to say it is unaffected by accident, not by design.

Three of the views are **nested**, so a fix must be applied at every level
[verified]: `export_360_giving` → `entity_location_details`, and both
`funding_revenue_candidates` and `programme_expense_candidates` →
`programme_funding_candidates`.

**Impact is latent, not live** — there is one tenant row in the demo data, and
`backend/tenants/tenants.json` is git-crypt encrypted so the deployed tenant
count is unknown [assumed single-tenant]. The defect is in the isolation
mechanism, which is load-bearing the moment a second tenant exists.

### 3.1.1 The fix, also verified

`ALTER VIEW … SET (security_invoker = true)` on all 12 views resolves it
completely, for both roles, with no over-blocking — each tenant sees exactly its
own row, and the owner (migrations, `pg_dump`) is unaffected [verified]. It is
safe here precisely because `pgutil`'s `perms()` already grants
`SELECT ON ALL TABLES` to `readonly_access`, which is what `security_invoker`
then checks.

`FORCE ROW LEVEL SECURITY` on the 41 tables also closes the leak, **but breaks
the owner** and should not be used. With FORCE applied, `admin` querying
`application` fails outright:

```
ERROR: unrecognized configuration parameter "rls.owner"
CONTEXT: SQL function "session_owner_id" statement 1
```

Because `session_tenant_id()` and `session_owner_id()` call
`current_setting('rls.tenant')` *without* the `missing_ok` argument
(`migrations/000000000000__rls.sql:19,23`) [verified by reading `prosrc` from
the live catalog], any session that has not set the variables errors rather
than returning NULL. That is a good fail-closed property in the request path —
but it means FORCE would break migrations and backups unless the helpers were
relaxed first, which would itself weaken the fail-closed behaviour. Recommend
`security_invoker`.

A regression test is cheap and currently absent: seed two tenants, scope a
session to one, assert every view returns only that tenant's rows.

### 3.2 `entity_status_changes` is written staff-owned

`entity.status()` inserts status-change rows with `owner_id` set to the
*tenant* id, not the entity's owner:

```sql
insert into entity_status_changes (entity_id, tenant_id, owner_id, status, changed_by)
values ($1, $2, $2, $3, $4)
```
(`foundational/entity.py:45`) [verified — `$2` is bound to
`context.tenant.identity` and supplied for both columns].

Under the access rules that makes every status change staff-owned: rule 1
(`session.owner = data.owner`) cannot match a customer session, and rule 3
(shared) does not apply. So an applicant organisation cannot read the status
history of its own application through the RLS path. Whether that is intended
privacy (status history is internal workings) or an oversight is not
determinable from the code [assumed intended, on the strength of the
`is_private` flag that `audit_log` carries for the same purpose]. Worth a
question.

Note also that `entity.status()` runs inside `systemcontext(context.tenant)`
(`entity.py:40`) [verified], so the write itself is privileged regardless.

## 4. Schema ownership

Three writers, cleanly separated by database principal [verified:
`backend/sql/pgutil:17-20,155-165`]:

| Principal | Role | Who uses it | Rights |
|---|---|---|---|
| `super` | — | `pgutil init/reset` | create/drop database |
| `admin` | owns all objects | migrations | DDL |
| `mutate` | `readwrite_access` | `api`, `integrations`, `broker`, `scheduler` | SELECT/INSERT/UPDATE/DELETE |
| `query` | `readonly_access` | the two BFFs | SELECT |

`REVOKE ALL ON _migrations` from both application roles (`pgutil:192-193`), so
the migration ledger is invisible to the running application [verified].

The BFF genuinely cannot write — the credential forbids it — which is what
makes the "all mutations through the API" rule in `01-architecture.md` §3
enforced rather than merely agreed. The §3.1 view issue is the exception that
matters: it does not grant writes, but it does defeat the read scoping.

**One schema-shaped thing lives outside the database entirely.** The ten
application statuses are enumerated canonically in TypeScript —
`APPLICATION_STATUSES` in
`frontend/foundational/utils/application-status.ts:17-28` [verified] — as
`draft, submitted, recommended, discommended, contested, accepted, rejected,
approved, denied, challenged`. There is no CHECK constraint, no Python enum,
and no transition table. `entity.progress()` writes whatever string it is
given (`foundational/entity.py:79-90`) [verified].

By contrast `ticket` *does* have a validated state machine: a `TRANSITIONS`
dict checked on every change, raising on an illegal move
(`foundational/workspaces/tickets.py:8,148`) [verified]. The newer subsystem is
the more rigorous one — the same pattern as the index coverage.

That file also records a genuine domain trap, quoted because the review should
not re-derive it: the database status `rejected` is "a peer review outcome that
is still awaiting authorisation", whereas the state-model row *named* "Rejected"
is the database status `denied`. They "are not the same thing and must not be
conflated" (`application-status.ts:11-14`).

## 5. The `formal` side-store

The rich user data — application forms, assessments, due-diligence reports — is
**not in the relational schema**. Three tables hold it
[verified: `migrations/000000000002__formal.sql`]:

| Table | Shape | Purpose |
|---|---|---|
| `formal_data` | `(id, tag, root, data bytea, schema_version, snapshot)` | the payload |
| `formal_flags` | 16 columns incl. `result`, `audience`, `decision` | problems lifted out so they are queryable |
| `formal_index` | `(node_id → object_id, entity_id, tag)` | reverse index from any node |

`formal_data.data` is a **Python pickle**:
`pickle.dumps(obj)` on write, `pickle.loads(...)` on read
(`foundational/formal/storage.py:87,108`) [verified — the local variable is
still named `jsondata`, which reads as a leftover from a JSON era].

Consequences, all [verified] by construction:

- The content is opaque to SQL. No predicate, projection or aggregate can reach
  inside a form. This is why the BFF's direct-read path cannot serve form data
  and must go through the API, and why `02`-level reporting on form answers has
  to be built by lifting fields out first.
- The format is coupled to the Python class graph. Renaming or relocating a
  `formal` class invalidates stored rows. `schema_version` and `snapshot`
  columns exist to manage this, and `snapshot()` creates a new generation
  rather than mutating (`storage.py:60-78`), so the mechanism is at least
  anticipated.
- Unpickling is arbitrary code execution. The data is written by the
  application itself, so this is not an external input path; but it does mean
  anyone with write access to one `bytea` column has code execution inside the
  API process. Worth a line in the review under trust boundaries rather than
  as a live vulnerability.

The design deliberately keeps the *queryable* parts out of the blob — flags go
to `formal_flags` so they can be listed in bulk for compliance staff, and
`formal_index` lets any node id resolve back to its object. The cost shows in
volume: 30,506 `formal_index` rows for 139 `formal_data` objects in the demo set
(~220 nodes per form) [verified].

`FORMAL.md` states the intent explicitly: this store is "primarily for during
active editing", and "finalised data should be moved to DB tables if needed".
How consistently that migration-to-relational actually happens is a question
for the review, not something the schema answers.

## 6. Money

Minor units in integers, by convention — 13 distinct `*_minor` column names
[verified]. Three inconsistencies sit inside that convention:

**Mixed widths.** `integer` in `project_payment_line_items` (`:535-541`),
`budget_line_item` (`:306-308`) and `project_payment_instructions` (`:1369`);
`bigint` in `application.application_grant_minor` (`:207`),
`project.funding_total_minor` (`:488`), `fund_revenue_period.amount_minor`
(`:841`) and `programme_expense_period.amount_minor` (`:882`) [verified]. A
4-byte `integer` of pence caps at **£21,474,836.47**. Whether any single
payment line item can approach that is a domain question — but the *aggregate*
columns are correctly `bigint` while the *line item* columns are not, which is
the wrong way round if anything.

**A non-conforming column.** `project.amount_awarded numeric` (`:493`) — no
minor-unit suffix, arbitrary precision, alongside `funding_total_minor bigint`
on the same table. It sits among the 360Giving export fields
(`funding_org_*`, `recipient_org_*`, `grant_programme_*`), so it is [assumed]
a reporting-shape column mirroring the 360Giving standard rather than an
operational one.

**Major units.** `programme.max_grant_major` and `min_grant_major`
(both `bigint`, `:859-860`) use *major* units in a schema whose convention is
minor [verified]. Two unit systems, distinguished only by suffix.

## 7. Ledger integrity

A real double-entry ledger: `ledger_accounts` (typed asset/liability/revenue/
expense/equity/memo), `ledger_entries` (credit/debit, enforced one-or-the-other
in code), `ledger_transactions` (grouped by `event_id`/`event_type`), and
`ledger_exports` [verified: `migrations/000000000003__ledger.sql`].

`ledger_accounts._balance` is a denormalised cached balance, maintained by
`commit()` (`finance/ledger/__init__.py:222-252`), and its own comment calls it
"the global unfiltered balance" [verified]. Writes are serialised by
`pg_advisory_xact_lock` (`:196`).

There **is** an invariant check — `assert_invariants()` verifies global
`sum(credit) = sum(debit)` and every cached `_balance` against its computed
balance, raising a `LedgerPanic` whose declared action is `lockdown`
(`:303-311`, `infra/panic.py:26-32`) [verified].

It is never called in the normal write path. Its only call sites are
`tests/test_ledger.py` (3×) and `rebalance_accounts()`, which is itself
reachable only from `api/endpoints/demo.py:57-58` — a module wrapped in
`if not config.is_production()` [verified by grepping every reference]. So the
mechanism to detect a ledger divergence exists, is tested, and does not run in
production. Its own comment anticipates the gap: "if an account `_balance` ever
diverges then this will be a major error. However, there is no way to recover
from it except to recalculate all balances from scratch" (`:315-317`).

Two TODOs in the migration are relevant and should be read as the authors'
own assessment: `ledger_transactions` should ideally be restricted to
SELECT/INSERT only — i.e. append-only — but is not, because of how migrations
run (`000000000003__ledger.sql:68-69`) [verified].

## 8. Shared mutable state

- **`entity.metadata jsonb`** on every business object, plus `metadata` or
  `properties` on 20 further tables (23 `jsonb` columns total). Untyped,
  unconstrained, and used as a per-entity key-value scratchpad — e.g.
  `applications.py` stores CSAT email bookkeeping under
  `META_CSAT_SUBMIT_SENT` and similar string keys
  (`entities/applications.py:19-22`) [verified]. Keys are string constants in
  Python with no schema; anything reading them from SQL or TypeScript is
  matching on a literal.
- **`entity.status text`** — single mutable status per entity, with history in
  `entity_status_changes` and a `revert` path (`entity.py:60`).
  `last_status_change_at` is additionally denormalised onto `project` (`:510`).
- **`ledger_accounts._balance`** — §7.
- **`geo_cache`** — a provider-response cache keyed by postcode/coords with
  partial unique indexes, the only table designed as cache [verified].

## 9. Migrations

Mechanics [verified: `backend/sql/pgutil`]:

- Forward-only. **No down migrations** — the vocabulary does not exist.
- Ledger table `_migrations (version text PK, description, sql text,
  executed_at)` stores the **full SQL text** of every applied migration
  (created at `:169-175`, written at `:84`), which is a nice audit property.
- `apply` selects `max(version)` (`:42`) and applies every file whose 12-digit
  prefix compares greater (`:71-87`). Serialised by `pg_advisory_lock(123456)`.
- Current range is `000000000000` … `000000000110`, 19 files.

Two things to carry into the review:

**(a) The generator and the convention disagree.** `pgutil migration <desc>`
names new files with `date "+%Y%m%d%H%M"` (`:307`) — e.g. `202610061530` —
while every existing migration uses a low sequential number [verified]. The
comparison itself is sound: `[ -gt ]` treats leading zeros as decimal, which I
confirmed empirically rather than assuming. But the first date-stamped
migration to be applied raises `max(version)` to ~2.0×10¹¹, after which **any
subsequently added low-numbered file is silently skipped** — no error, just
absent. Two of the last three migrations (`109`, `110`) were hand-numbered in
the old scheme, so the convention in use is not the one the tool produces.

**(b) `restore` does not stop on error.** `pgutil restore` runs
`psql $admin -f $path/data.sql` with no `-v ON_ERROR_STOP=on` (`:274`), directly
below a commented-out line that *does* have it (`:273`) [verified]. Every other
`psql` invocation in the file uses `ON_ERROR_STOP` — the shared `execute`
helper at `:220` and the `import` command at `:287-288`. So a
restore that half-fails reports success — and `just restore` is the documented
way to prepare a database for login and E2E testing.

**Committed dumps.** Three data exports live in git totalling ~73 MB:
`export/data.sql` and `export/demo/data.sql` (both exactly 23,901,875 bytes but
differing in content — md5 `9f34b05e…` vs `2534197c…`, so regenerations rather
than copies) and `export/scenarios/data.sql` (25,766,945 bytes), plus four
identical `schema.sql` copies and a 15k-line `export-20260219.tgz`
[verified]. They dominate the repo's line count: they make
`backend/sql` read as 141,650 lines when the hand-written part is ~1,500.

## 10. Views

12 views; 9 are referenced, 3 are not [verified by grepping both stacks]:

| View | Backend refs | Frontend refs |
|---|---|---|
| `project_payment_schedule` | 4 | 10 |
| `inferred_assignments` | 0 | 6 |
| `entity_owners` | 3 | 0 |
| `user_roles_derived` | 3 | 0 |
| `export_360_giving` | 0 | 2 |
| `programme_funding_allocations` | 0 | 2 |
| `user_organisational_roles_summary` | 0 | 1 |
| `entity_location_details` | 1 | 0 |
| `programme_funding_candidates` | 1 | 0 |
| `financial_planning` | 0 | 0 |
| `funding_revenue_candidates` | 0 | 0 |
| `programme_expense_candidates` | 0 | 0 |

The last three are dead as far as static reference goes [verified]; they may
still be used ad hoc by analysts [assumed], which is exactly the use the README
invites when it describes read-only Postgres access "for ad-hoc queries".

## 11. Open questions for the team

1. §3.1 — the view bypass is confirmed, so the question is no longer whether
   but what next: is there any deployed environment with more than one tenant
   row (i.e. is this live rather than latent), and who owns applying
   `security_invoker` plus the two-tenant regression test?
2. §3 — is the un-policied set deliberate? Specifically `user_roles`,
   `stripe_*`, `sent_emails`, `api_calls`.
3. §3.2 — should an applicant be able to see its own application's status
   history?
4. §2.1 — is the absence of primary keys and core indexes a known consequence
   of the inheritance choice, or has it gone unnoticed?
5. §6 — can a single payment line item exceed £21.4m?
6. §7 — should `assert_invariants()` run on a schedule, or after each
   `commit()`?
7. §9 — which migration numbering scheme is canonical?
8. §5 — is pickle a deliberate choice, and is there a plan for class-rename
   migrations?
