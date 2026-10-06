<!-- reviewed at commit 58fbc761 on 2026-10-06 -->
# InvestEngland — architecture

Scope: how the system is put together — services, module boundaries, dependency
direction, and the cross-cutting mechanisms (tenancy, auth, async, integrations).
Data model detail is deferred to `02-data-model.md`, interface detail to
`03-apis.md`. Every claim below is labelled `[verified]` (read in code at
`58fbc761`) or `[assumed]`.

---

## 1. Runtime topology

Seven deployable units, built from two Dockerfiles as multi-stage targets
[verified: `backend/Dockerfile`, `frontend/Dockerfile`, `.github/workflows/main.yml`].

| Unit | Language | Entry point | Local port |
|---|---|---|---|
| `grantseekers` (public portal) | TS | `frontend/grantseekers/app/root.tsx` | 8001 |
| `grantmakers` (staff back-office) | TS | `frontend/grantmakers/app/root.tsx` | 8002 |
| `api` | Python | `backend/api/app.py` | 8080 |
| `integrations` | Python | `backend/integrations/integrations.py` | 8081 |
| `broker` | Python | `backend/broker/broker.py` (cmd `broker`) | — |
| `scheduler` | Python | same module, cmd `scheduler` | — |
| `migrations` | bash | `backend/sql/pgutil` | — |

Supporting services: Postgres 16, Redis, and a Caddy 2.9 gateway
[verified: `docker-compose.yml`].

`broker` and `scheduler` are the **same image and the same code**, differing
only in the command passed (`backend/Dockerfile:30-38`). The README's reference
to a `backend/scheduler` directory is doc drift — no such directory exists
[verified].

The Caddy gateway maps `external.localhost`→8001, `internal.localhost`→8002,
`backend.localhost`→8080, `integrations.localhost`→8081
[verified: `gateway/etc/caddy/Caddyfile`]. The gateway is **not** one of the
seven images pushed to Azure, so in deployed environments Container Apps
ingress takes its place [verified for the absence; the substitution is
[assumed] — there is no IaC in the repo to confirm it].

```
                  ┌─────────────┐
   applicants ───▶│ grantseekers│──┐
                  └─────────────┘  │  HTTP (X-API-Key / Bearer JWT)
                  ┌─────────────┐  ├──────────▶┌─────┐
   SE staff ─────▶│ grantmakers │──┘           │ api │──┐
                  └─────────────┘              └─────┘  │
                         │  read-only SQL         │     │
                         │  (RLS session vars)    │     │ asyncpg
                         ▼                        ▼     ▼
                    ┌──────────────────────────────────────┐
                    │              Postgres 16             │
                    └──────────────────────────────────────┘
                              ▲              ▲
                     ┌────────┘              └────────┐
              ┌───────────┐                     ┌──────────────┐
              │  broker   │◀── Redis queue ─────│  (producers) │
              │ scheduler │                     └──────────────┘
              └───────────┘
                     │
                     ▼  HTTP, tenant API key
              ┌──────────────┐
              │ integrations │──▶ Creditsafe, Companies House,
              └──────────────┘    Credas, PTX, NetSuite, OS Places, …
```

## 2. Layering

### 2.1 Backend

Four layers, and the direction is clean between them [verified]:

```
api/endpoints/*        transport: route, authorise, delegate. 2,042 lines total.
      │
      ▼
foundational/*         domain logic. 16,156 lines, 89 modules, 12 areas.
      │
      ▼
vendor/unrest          framework: routing, serialisation, db pool, tasks. 2,223 lines.
      │
      ▼
Postgres / Redis
```

`api/endpoints` is genuinely thin — handlers are typically a permission
decorator plus one delegating call, e.g.
`backend/api/endpoints/applications.py:21-42`. Nothing in `foundational`
imports `endpoints` [verified], so the transport layer is substitutable; the
`integrations` service is a second consumer of the same domain library.

`unrest` is **vendored into the repo** as a develop-mode path dependency
(`backend/foundational/pyproject.toml:18`), not pinned to the upstream git tag
that is commented out one line above in `backend/api/pyproject.toml:11-13`. The
framework is therefore editable in-tree, and the boundary between "our code"
and "the framework" is advisory rather than enforced [verified].

### 2.2 Frontend

```
app/routes/**              105 routes (grantmakers) + 86 (grantseekers)
      │
      ▼
@foundational/core/*.ts    domain modules, each a class extending Module
      │
      ├──▶ Module.post()/get()  ──▶ api service   (all mutations)
      └──▶ sql``                ──▶ Postgres      (reads only)
```

Routes do not reach past the domain modules: zero route files import
`.server/modules` directly [verified], and only one route imports the SQL
helper (`grantseekers/app/routes/customer.tsx`) [verified]. Direct SQL is
otherwise confined to 15 modules under `frontend/foundational/` [verified].

The per-app `app/.server/*.ts` files are **not** duplicates of the shared ones
— each is a 2–3 line re-export shim, present so React Router does not bundle
server code into the client build [verified: `grantmakers/app/.server/db.ts` is
one comment plus one `export *`]. All seven shims are byte-identical between
the two apps.

## 3. The BFF seam

This is the most consequential design decision in the system, and it is
deliberate [verified: README "Orientation", `docs/BFF-INTEGRATION.md`]:

- **All mutations** go through the `api` service over HTTP.
- **Reads** may bypass the API and query Postgres directly from the frontend
  server, using a **read-only** connection string
  (`config.readonlyPostgresUrl`, `frontend/foundational/.server/db.ts:8`).

The read path is safe-by-construction in two ways: the credential cannot write,
and every query is wrapped in a transaction that sets the RLS session variables
first (`frontend/foundational/.server/db.ts:20-28`).

```
                              browser
                                 │  form data (default) / GET
                                 ▼
                  ┌────────────────────────────┐
                  │  route loader / action     │  grantmakers / grantseekers
                  └──────────────┬─────────────┘
                                 │
                MUTATE  ┌────────┴────────┐  READ
                        │                 │
                        ▼                 ▼
                 Module.post()        sql`…` wrapper
                 · HTTP               · BEGIN
                 · Bearer JWT         · set_config('rls.tenant', …)
                 · X-API-Key          · set_config('rls.owner',  …)
                 · X-Tenant-Domain    · ‹query›
                        │                 │
                        ▼                 │
                   ┌─────────┐            │
                   │   api   │            │
                   └────┬────┘            │
                        │ asyncpg         │
           POSTGRES_MUTATE_URI     POSTGRES_QUERY_URI
           role: readwrite_access  role: readonly_access
           (SELECT/INSERT/         (SELECT only — the credential
            UPDATE/DELETE)          itself forbids writes)
                        │                 │
                        └────────┬────────┘
                                 ▼
                           Postgres 16
                      RLS on 41 of 59 tables
```

Two properties fall out of this shape. The "all mutations via the API" rule is
enforced by the credential, not by agreement — the BFF physically cannot write.
But the read path makes the schema a frontend interface, which is finding **F6**,
and the RLS wrapper it depends on is bypassed for views, which is **F2**.

Consequences worth carrying into the review: a screen's data needs are
satisfiable without an API endpoint, which keeps the API small, but it also
means **the database schema is a public interface of the frontend**. A column
rename ripples into `frontend/foundational/*.ts` with no compiler or contract
to catch it. 15 modules import the SQL helper; 35 executed query sites exist
across 11 files [verified]. The gap is files importing only `_sql` to build
query *fragments* (identifiers, conditional `where` clauses) rather than to
run a query.

One acknowledged leak in the other direction: the BFF calls `POST /audit`
directly, which the backend itself flags as wrong in a `FIXME`
(`backend/api/endpoints/__init__.py:42-46`) with a matching `TODO` on the
calling side (`frontend/foundational/.server/modules.ts:48`). Both sides agree
it should go; neither has removed it [verified].

## 4. Multi-tenancy and authorisation

Tenancy is enforced in **Postgres**, not in application code
[verified: `backend/sql/migrations/000000000000__rls.sql`].

A two-attribute model — `tenant_id` + `owner_id` — is applied by a single
helper, `apply_ownership_policies(regclass)` (`:35-76`), which generates four
policies (select/insert/update/delete) against two session variables,
`rls.tenant` and `rls.owner`. The access rules are:

| Rule | Condition | Effect |
|---|---|---|
| 0 | `session.tenant = data.tenant` | always required |
| 1 | `session.owner = data.owner` | owner read/write |
| 2 | `session.owner = session.tenant` | staff read/write |
| 3 | `data.owner = 000…0` | shared, readable by all |

The two columns live on base tables that business tables inherit from. The
architectural consequence is that **RLS policies do not descend through
Postgres inheritance**, so the helper must be invoked per child table — a
constraint the migration notes in a comment ("Annoyingly, we have to apply
policies on the child tables") [verified: `000000000000__rls.sql:221`]. The
inheritance model itself, and the other three things that fail to descend, are
`02-data-model.md` §2.

How a row is evaluated — and where that evaluation is skipped:

```
   query against a TABLE                     query against a VIEW
   runs as the connected role                runs as the VIEW OWNER (admin),
   (queryuser / mutateuser)                  because no view sets security_invoker
            │                                          │
            ▼                                          ▼
   ┌─────────────────────┐                  ┌──────────────────────────┐
   │ RLS policies apply  │                  │ owner is exempt from RLS │
   └──────────┬──────────┘                  │ (no FORCE ROW LEVEL SEC) │
              │                             └────────────┬─────────────┘
              ▼                                          ▼
   rule 0:  row.tenant_id = rls.tenant ?       EVERY ROW, EVERY TENANT
            │                                   ⚠ verified defect — F2
       no ──┴──▶ row hidden
      yes
       │
       ├─ rule 1   row.owner_id = rls.owner   ──▶ visible  (owner's own data)
       ├─ rule 2   rls.owner    = rls.tenant  ──▶ visible  (staff session)
       ├─ rule 3   row.owner_id = 000…0       ──▶ visible  (shared reference)
       └─ otherwise                           ──▶ row hidden
```

The left-hand path is correct and was confirmed working. The right-hand path is
finding **F2** — verified by execution, affecting 11 of 12 views and both
application roles. Detail and repro in `02-data-model.md` §3.1.

Coverage is partial — 41 of 59 tables are policied, and the exclusions are
catalogued with their justifications in `02-data-model.md` §3, which also owns
the principal inventory and table-level rights (§4).

The architectural half of that is pool selection: `unrest` picks the connection
pool from the request's operational context — mutate contexts get the writer,
query contexts the reader (`vendor/unrest/unrest/db/pool.py:100-119`). This is
the mechanism behind the framework's "strong distinction between `query` and
`mutate`" that the README mentions; `@api.query` registers GET/QUERY,
`@api.mutate` registers POST (`vendor/unrest/unrest/api/__init__.py:89-107`).
Because the two pools authenticate as different Postgres roles, the read/write
split is enforced by credential rather than by convention [verified].

**Application-level authorisation** is a claims model: 30 `Roles` attributes over 29 distinct
permission names — `Roles.user` is a composition,
`Permission("customer") | Permission("staff")` — as composable `Permission`
objects (`foundational/authz.py:17-51`), checked as
decorator arguments on endpoints (`Roles.customer`, `Roles.can_batch_payments`,
…). The frontend mirrors this with `assertRole`/`assertWritableRole` on the
BFF modules (`.server/modules.ts:25-47`), where a claim grants write only if
its value is truthy.

### 4.1 Environment-keyed gates

Several security-relevant behaviours are switched on a single environment
string, and this is the system's weakest seam [verified].

`Permission.__call__` returns `True` unconditionally when
`config.is_development()` (`foundational/authz.py:9-15`), and the API's tenant
resolution substitutes a hardcoded domain in the same condition
(`api/endpoints/auth.py:46-47`). Correct for local work; it means permission
behaviour is **not** exercised by anything running in development mode.

More consequentially, `is_production()` is defined as
`get("ENVIRONMENT") == "production"`
(`vendor/unrest/unrest/contexts/config.py:13-14`) — while three comments in
three files state that Azure sets `ENVIRONMENT=live`, including on live itself
(`config.py:19-20`; `foundational/authn.py:28-29`;
`frontend/foundational/.server/configuration.ts:49-50`). The team worked around
this by introducing a separate `ARENA_TIER` variable and `is_internal_tier()`,
and used *that* to gate OTP bypass and the email whitelist — but
`is_production()` still gates the demo endpoints (`api/endpoints/demo.py:13`)
and the API documentation routes (`api/endpoints/__init__.py:195,202,239`).

So the codebase contains two generations of environment detection: the original
`ENVIRONMENT`-keyed one, known to be wrong and still load-bearing for two
things, and the `ARENA_TIER`-keyed replacement that fails safe. See **F1** in
`reviews/2026-10-06-investengland.md` — this is the review's top finding, and
the architectural point is that the gate is a negative check (`if not
production`) on an untrusted string, which fails *open*.

Tenant resolution at the edge: `X-API-Key` if present, else the
`X-Tenant-Domain` header forwarded by the BFF from the request hostname
(`api/endpoints/auth.py:40-52`). The handler's own comment explains the
fallback is a concession — the API cannot rely on its own hostname
identifying the tenant.

## 5. Dependency direction inside `foundational`

This is the weakest structural area, and the one to carry into the review.

Cross-area imports were extracted from all 89 modules under
`backend/foundational/foundational/`. **Eight mutually-dependent area pairs**
exist [verified]:

| Pair | Direction A | Direction B | Both top-level? |
|---|---|---|---|
| `entities` ↔ `formal` | 21 top-level | 1 top-level | **yes** |
| `entities` ↔ `infra` | 8 top + 5 deferred | 6 top-level | **yes** |
| `entities` ↔ `compliance` | 4 top + 5 deferred | 6 top + 3 deferred | **yes** |
| `entities` ↔ `schema` | 3 top-level | 3 top-level | **yes** |
| `entities` ↔ `finance` | 3 deferred | 6 top + 2 deferred | no |
| `entities` ↔ `integrations` | 4 deferred | 1 top-level | no |
| `compliance` ↔ `integrations` | 7 deferred | 6 top-level | no |
| `finance` ↔ `integrations` | 1 deferred | 7 top-level | no |

The distinction matters. In the four "no" rows, one direction is exclusively
**function-local** (indented) imports — the standard Python idiom for breaking
an import cycle deliberately, e.g.
`foundational/finance/payments/processing.py:116`. Those are managed cycles.

The four "yes" rows are genuine top-level cycles: `entities/applications.py:6-7`
imports `formal` while `formal/attachments.py:3` imports `entities.files`;
`infra/tickets.py:13` imports `entities.files` while `entities/applications.py:15`
imports `infra.mailer`; `schema/duediligence.py:2-4` and
`entities/organisations.py:16-17` import each other's areas. Python tolerates
these as long as the import order happens to work, which makes module load
order load-bearing and the areas effectively one unit for refactoring purposes.

`entities` is the hub: it is the source or target of 6 of the 8 cycles, and
`entities/organisations.py` (745 lines) is the single largest domain module.
A plausible reading is that `entities` holds both data definitions and
orchestration, so everything needs it and it needs everything [assumed —
confirming this requires reading the modules, not the import graph].

Layer-respecting dependencies by contrast: `tasks → entities/finance/infra`
(one-way), `tenants → entities` (one-way), `authn → infra/entities/schema`
(one-way) [verified].

## 6. The integrations seam

The cleanest abstraction in the codebase [verified].

`foundational` declares abstract service interfaces —
`AntiMoneyLaunderingService`, `DueDiligenceService`,
`IdentityVerificationService`, `BankDetailsService`, `PaymentsService`,
`LedgerService`, and three geo services. A string-keyed registry maps
`"domain:provider"` to an implementation via an `@integration` decorator
(`foundational/integrations/__init__.py:13-23`).

Resolution is per-tenant and runtime
(`foundational/integrations/__init__.py:25-41`): the tenant's `integrations`
config supplies a provider name, falling back to a hardcoded default
(`aml`→`creditsafe`, `pay`→`ptx`, `id`→`credas`, …). **If the configured value
starts with `http`, the `$proxy` implementation is selected instead** — an
HTTP client that forwards the same interface call to the `integrations` service
authenticated with the tenant's API key
(`foundational/integrations/proxies.py:22-62`).

```
  domain code:  client = await get_aml_client()
                       │
                       ▼
    tenant.integrations['aml'] ── unset ──▶ hardcoded default: 'creditsafe'
                       │                                 │
                       └────────────────┬────────────────┘
                                        ▼
                           value starts with 'http' ?
                      no  ┌─────────────┴─────────────┐  yes
                          ▼                           ▼
            registry['aml:creditsafe']      registry['aml:$proxy'](url)
                          │                           │
                          ▼                           ▼
            CreditsafeAntiMoney…            ProxyAntiMoney…
            (in-process, implements         (implements the SAME
             AntiMoneyLaunderingService)     interface, over HTTP)
                                                      │
                                        HTTP + tenant API key
                                                      ▼
                                         ┌──────────────────────┐
                                         │ integrations service │
                                         └──────────┬───────────┘
                                                    ▼
                                      registry['aml:creditsafe']
                                      implementations/aml/creditsafe.py
```

So the same domain code runs against a real provider in-process or against a
remote provider over HTTP, chosen by configuration, with no call-site change.
The `$proxy` implementation satisfies the same abstract interface as the real
one, which is what makes the substitution invisible to the caller.
Concrete providers live only in `backend/integrations/implementations/`
(13 files across aml, finance, geo, kyb, kyc, payments) and are imported solely
by the integrations service entry point
(`backend/integrations/integrations.py:18`) [verified]. The domain layer never
imports a vendor SDK directly.

## 7. Asynchronous work

Taskiq over a Redis `ListQueueBroker`, with an in-memory broker substituted
under test (`backend/vendor/unrest/unrest/tasks.py:40-52`) [verified].

- **Background tasks**: 8 declared via `@background(...)`, which optionally
  takes a permission predicate (`finance/payments/processing.py:167` requires
  `can_authorise_payments`) [verified].
- **Scheduled tasks**: 13 cron-declared jobs in
  `foundational/tasks/scheduled/__init__.py`, from `* * * * *`
  (ledger export) to daily (`0 9 * * *` award offer expiry) [verified].

Two framework rules shape the design: the calling request's context is
serialised into the task payload and restored in the worker
(`tasks.py:69-104`), so tenant and user identity survive the queue hop; and
**a background task may not trigger another background task** — it raises
(`tasks.py:114-118`) [verified]. Task results expire from Redis after 3600s
(`tasks.py:47`).

## 8. Cross-cutting concerns

**Request context** — both stacks use ambient per-request context rather than
parameter threading: `AsyncLocalStorage` in the BFF
(`frontend/foundational/.server/context.ts:50-69`) and a context object in
`unrest` carrying tenant, user, and the query/mutate flag. Convenient, and it
means a function's real inputs are not visible in its signature.

**Logging** — structured JSON to stderr, with context and user injected into
every record (`vendor/unrest/unrest/contexts/observability.py:11-21`). Note
`getLogger` reconfigures *every* third-party logger it has not seen to ERROR
level (`:39-50`), i.e. the framework claims the global logging config.

**Errors** — a six-type exception hierarchy in `unrest` mapped to HTTP status
in middleware. `docs/ERRORS.md` is accurate: the mapping it tabulates matches
`vendor/unrest/unrest/routing.py:122-161` exactly, including 404/409/409/400 for
`NotFoundError`/`InvalidStateError`/`ConcurrencyError`/`ClientError`, 403 for
asyncpg's `InsufficientPrivilegeError`, and full messages at 500 only when
`verbose_errors` is set [verified].

**Dynamic data and forms** — the `formal` library (1,807 lines across 11
modules, `foundational/formal/`) stores rich data as an annotated JSON dialect
with `$`-prefixed metadata (`$valid`, `$complete`, `$errors`, `$flags`),
designed so field-level validation failures and due-diligence flags are both
co-located with the data and queryable in bulk
[verified: `backend/foundational/FORMAL.md`]. It has a matching TS
implementation (`frontend/foundational/formal/`, 9 files). This is the one
place the README admits to a bespoke framework, and it is described as "in
ongoing development".

## 9. Observed boundary violations

Two, both small, recorded here as facts for the review to rate:

1. `frontend/grantseekers/app/routes/healthcheck.tsx:2` imports
   `@foundational/grantmakers/.server/health` — the public app depending on the
   staff app. `grantmakers` is **not** a declared dependency of `grantseekers`
   (`grantseekers/package.json`) [verified]; it presumably resolves through
   pnpm workspace hoisting [assumed]. The imported symbol is a 3-line function
   that the grantmakers shim merely re-exports from `@foundational/core`, so
   the fix is a one-line import change. Otherwise the two apps are cleanly
   separated — no other cross-app import exists in either direction, and the
   shared library imports neither app [verified].
2. The `POST /audit` BFF-to-API call described in §3, flagged by `FIXME` and
   `TODO` on both sides.

## 10. Open questions for the team

- Is the un-RLS'd remainder of §4 (notably `stripe_*`, `sent_emails`,
  `api_calls`) deliberate, or has the helper simply not been applied?
- Is `unrest` intended to return to a pinned upstream dependency, or is the
  vendored copy now the real home?
- Is the `entities` hub in §5 understood as debt, or is the current shape
  intended?
