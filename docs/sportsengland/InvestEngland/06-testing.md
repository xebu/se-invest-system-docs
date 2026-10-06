<!-- reviewed at commit 58fbc761 on 2026-10-06 -->
# InvestEngland — testing

Scope: what is tested, what is executed, what is mocked, and what is critical
and untested. Claims are `[verified]` or `[assumed]`.

The distinction between **written** and **executed** does most of the work in
this document, so it is worth stating the method: every count below was taken
by parsing test files for test functions, then tracing each suite back through
`justfile` recipes and `.github/workflows/` to see whether any CI path reaches
it.

## What matters here

1. **The repo contains a thorough RLS tenant-isolation test suite that never
   runs** — it defines no pytest-collectable functions, is invoked only by a
   manual `just` recipe, and tests tables but not views. That is the direct
   explanation for how finding **F2** survived (§3).
2. **Three test suites are orphaned** — `backend/api/tests`,
   `backend/integrations/tests` and `vendor/unrest/tests`, 36 test functions
   between them, reachable by no CI path. Two `entrypoint.sh` files have
   `poetry run pytest` commented out (§2).
3. **One test actively misleads**: it asserts the production gate works by
   setting `ENVIRONMENT="production"`, a value the deployment appears never to
   use (§5, finding **F1**).
4. **No coverage measurement anywhere** — `coverage` is a declared dev
   dependency and is invoked by nothing (§6).

What *is* executed is substantial and good: 529 backend test functions over real
domain logic against a real database, 218 frontend unit tests, and 78 Playwright
scenarios across both portals.

---

## 1. Inventory

| Suite | Files | Test functions | Executed in CI? |
|---|---|---|---|
| `backend/foundational/tests` | 47 | **529** | **yes** |
| `frontend/**` unit (Vitest) | 37 | **218** | **yes** |
| `frontend/**/e2e` (Playwright) | 18 | **78** | **yes** |
| `backend/api/tests` | 1 | 2 | **no** |
| `backend/integrations/tests` | 5 | 32 | **no** |
| `backend/vendor/unrest/tests` | 1 | 2 | **no** |
| `foundational/tests/demo/test_rls.py` | 1 | 0 collectable | **no** |

[verified by counting `def test_` / `it(` / `test(` declarations and tracing
execution paths.]

So **825 test functions run** and **36 do not**, plus the RLS suite which is not
counted because it exposes no test functions at all.

## 2. What CI actually executes

`.github/workflows/test.yml` runs on every branch push — note the `'**'` glob,
with a comment explaining that a previous `'*'` "silently never tested" any
branch with a prefix like `fix/` [verified]. Someone found and fixed that, and
left the reasoning in place.

Its steps [verified]:

| Step | Command | Reaches |
|---|---|---|
| Test | `just ci-test` | `backend/foundational` only |
| Test frontend unit tests | `just test-frontend` | both apps' Vitest |
| Test UI | `just ci-test-ui` | both apps' Playwright |

The first step is narrower than it looks. `just ci-test` is
`docker compose exec api api/entrypoint.sh test`, and that entrypoint does
[verified: `backend/api/entrypoint.sh:25-28`]:

```sh
"test")
    cd ../foundational
    poetry run pytest
;;
```

It changes directory **out of** `api/` and runs `foundational`'s suite. So the
API service's own tests are never run by the step that appears to run them. And
`just ci-test` carries a commented-out second line
(`justfile:211-213`) [verified]:

```make
ci-test: reset
    docker compose exec api api/entrypoint.sh test
    # docker compose exec grantmakers grantmakers/entrypoint.sh test
```

The same pattern appears in two more entrypoints [verified]:

- `backend/integrations/entrypoint.sh:26` — `# poetry run pytest`
- `backend/broker/entrypoint.sh:30` — `# poetry run pytest`

Four commented-out test invocations across three files. Three of them are
orphaned suites that were switched off with no recorded reason. The fourth has a
simpler explanation: `frontend/grantmakers/entrypoint.sh` **does not exist**
[verified], so that line could never have worked — it is aspirational rather
than disabled.

What is orphaned matters more than the count. `backend/integrations/tests`
covers the **third-party provider adapters**: `test_netsuite.py` (10 tests),
`test_integrations.py` (6), `test_geo.py` (4), `test_kyb_config.py` (2),
`test_ptx.py` (1), plus class-based tests in `test_credas.py` and
`test_creditsafe.py` [verified]. These are the ledger export, the payment
instruction format and the KYC client — the code where a provider's API change
breaks money movement, and the code a developer is least likely to exercise by
hand.

## 3. The RLS suite that does not run

This is the most consequential finding in this document, because it explains
**F2**.

`backend/foundational/tests/demo/test_rls.py` is a serious piece of work. Its
header states the intent [verified]:

> This script validates that Postgres Row-Level Security policies correctly
> enforce tenant and organisation isolation across every RLS-protected table.
> … RLS enforces two absolute isolation boundaries: 1. Tenant isolation — a
> session in tenant A can never read or write data belonging to tenant B.
> 2. Organisation isolation — a customer scoped to org A can never read or
> write data owned by org B, and cannot impersonate staff by writing with
> owner_id = tenant_id.

And it delivers on that: it defines `run_read_tests`, `run_insert_tests`,
`run_update_tests`, `run_delete_tests`, builds a cross-tenant actor
(`create_cross_tenant_actor`, used at `:755`), finds two orgs
with customers and a customer with no org, and even calls `seed_empty_tables`
so that no RLS-protected table is skipped for want of data [verified].

Three facts about it, each verified:

1. **It defines no pytest-collectable test functions.** Every function is a
   helper or a runner; the entry point is
   `if __name__ == "__main__": loop.run_until_complete(main())`. A grep for
   `^\s*(async )?def test_` returns nothing. Since it lives under
   `testpaths = ["tests"]` and is named `test_rls.py`, pytest imports it and
   collects **zero** tests — silently. It therefore contributes nothing to the
   529 figure, and nothing to CI, while appearing in every file listing as a
   test.
2. **It is invoked only by a manual recipe** — `just testrls`, which runs
   `poetry run python tests/demo/test_rls.py` (`justfile:306-309`). No CI
   workflow calls it.
3. **It tests tables, not views.** A case-insensitive search for `view`,
   `project_payment_schedule` or `security_invoker` in the file returns **zero**
   matches.

So the property F2 breaks — tenant isolation — has a dedicated, well-designed
test suite in this repository, and that suite (a) never runs automatically and
(b) would not have caught F2 even if it did, because it exercises the table path
and the defect is in the view path.

That is a more interesting failure than "they forgot to test it". They did test
it, carefully, and the test's blind spot and its execution gap lined up exactly
with the defect.

**Recommended action**, in order:
1. Convert `test_rls.py` into collectable pytest tests (or rename it so it stops
   presenting as one) and add it to CI.
2. Extend it to iterate the 12 views as well as the 41 tables — which turns
   `verification/2026-10-06-rls-view-bypass.sh` into a permanent regression
   test rather than a one-off repro.

## 4. The executed backend suite

529 test functions across 47 files, and the coverage is genuinely domain-shaped
rather than unit-trivial [verified from filenames and contents]: payments and
payment processing, ledger, budget, claims, awards, conditions, due diligence,
KYC, applications and status transitions, assessments, rejections, programmes
and programme config, organisations, membership, contacts and contact roles,
roles and admin roles, workspaces, tenants, files, email, geo, locations,
information requests, M&E surveys, formal and formal effects, audit coverage,
API error shapes, file-download security, security logging, background jobs,
panics.

**It runs against a real database, not mocks.** `conftest.py` builds users
through the actual authentication path — `authn.get_or_create_user`,
`authn.login`, `authn.login_verify(login_id, "000000")`,
`authn.authenticate_jwt_token` — and wraps assertions in `usercontext(user,
tenant)` [verified]. `just test-backend` depends on `reset`, which drops and
recreates the schema first [verified: `justfile:94`]. Fixtures come from CSVs
(`admins.csv`, `customers.csv`, `knownpostcodes.csv`, `roles.csv`) and
Faker.

This is the right trade for this system. The business logic is inseparable from
RLS, Postgres table inheritance and the `formal` store, so testing it against
SQLite or mocks would test something else. The README's claim that business
logic "should be tested directly with minimal integration beyond the database"
matches what the tests actually do — a rare alignment.

Two supporting tools are wired in and worth knowing about: `pyleak` is a
declared dependency, and `tests/profiler.py` plus the `just timetests` and
`just profile` recipes exist for per-test timing and `gprof2dot` profiling
[verified]. Someone has had a performance problem in the suite before.

## 5. The test that misleads

`backend/api/tests/test_api_docs_endpoints.py` contains two tests
[verified]:

```python
def test_api_docs_endpoints_available_in_development(monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "development")
    ...  # asserts /openapi.json, /docs, /redoc all return 200

def test_api_docs_endpoints_return_404_in_production(monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "production")
    ...  # asserts all three return 404
```

The second test asserts exactly the right property. It sets `ENVIRONMENT` to
`"production"` — a value that, per three comments in the codebase, Azure never
sets (`05-deployment.md` §5). So the test passes, and the deployed behaviour is
the opposite of what it certifies.

It is also in the orphaned `backend/api/tests` directory, so it does not run in
CI either (§2) — which means it provides neither real assurance nor even
nominal assurance. But the more instructive point is the first one: **a passing
test can encode an assumption about the environment that the environment does
not satisfy.** The literal string `"production"` appears as an `ENVIRONMENT`
value nowhere else in the repository; `test_email.py` uses `"demo"` and
`"live"` [verified], which is what the deployment actually uses.

**Recommended action:** parameterise the test over the values deployments
really use — `live`, `dev`, `sit`, `uat`, `demo` — and assert the gate closes
for `live`. That single change converts F1 from invisible to caught.

## 6. Coverage, and what is untested

**There is no coverage measurement.** `coverage ^7.13.2` is a declared dev
dependency of `foundational` and is invoked by no recipe, no entrypoint and no
workflow [verified]. So the figures in §1 are test *counts*, and no one — me
included — can say what fraction of the code they exercise.

Known gaps, in rough order of how much they would matter:

| Gap | Why it matters |
|---|---|
| Views / RLS-through-views | §3 — finding **F2**, verified defect, zero tests |
| Multi-tenant isolation in CI | §3 — the suite exists but never runs |
| Third-party adapters | §2 — ledger export, payment instructions, KYC clients orphaned |
| `unrest` framework | 2 tests for 2,223 lines of routing/auth/serialisation/pool, not run (`04-dependencies.md` §5) |
| API transport layer | 164 endpoints; the only test file for them is orphaned and misleading |
| Migration correctness | no test applies migrations to a populated database and asserts the result; migration 110 does its own duplicate check in SQL, which is the closest thing |
| Deploy-order mismatch | `05-deployment.md` §3.2(b) — nothing tests new code against the previous schema |
| Ledger invariants | `assert_invariants()` is *only* reachable from tests (finding **F5**) — the inverse problem: well tested, never run in production |

The last row is worth dwelling on, because it is the mirror image of §3. The
ledger invariant check is exercised by three tests and by nothing else; the RLS
isolation check is exercised by a suite that never runs. In both cases a
correct, well-written safety mechanism exists and is not connected to the place
it would do its job.

## 7. Frontend and end-to-end

**Unit (Vitest)** — 218 tests in 37 files, concentrated in `grantmakers`
(~30 files) with ~7 in `grantseekers` and **none** in the shared
`@foundational/core`, which declares no `test` script at all — so
`pnpm --recursive run test` skips it silently [verified]. That distribution is upside down relative to
risk: the shared library holds the BFF modules, the 35 direct SQL call sites and
the `formal` TypeScript implementation, and has no unit tests at all. The tested
things are mostly route-level and component-level in the staff portal —
payment batching, payment authorisation, payment selection, application status,
ticket editability, bulk assignee, finance stats, read-only access for SE
staff. Sensible choices individually; the gap is structural.

**End-to-end (Playwright)** — 78 tests in 18 spec files, split across both
portals [verified]. `grantmakers`: auth, award close, finance batch totals,
finance payments and payment roles, organisations, project and review contacts,
SE application viewing. `grantseekers`: auth, applications, awards, funds,
payments, register, register-organisation, find-organisation, error boundary.
Separate `auth.setup.ts` and `awarded.setup.ts` projects seed authenticated
storage state (`storageState: ".auth/user.json"`) [verified].

The E2E suite covers the money path end to end, which is the right priority. It
depends on seeded demo data (`just demo 10` or `just restore`) and on the TLS
gateway, with a documented `frontend/.env.local` override because
`network_mode: "host"` does not work on macOS or Windows [verified] — and the
Playwright configs load `.env.local` before `.env` so local overrides win while
CI silently skips the file. That is a well-handled piece of developer
experience.

CI uploads the Playwright HTML report as an artefact on failure and writes
instructions for viewing it into `$GITHUB_STEP_SUMMARY` [verified]. Also good.

One dependency to note: E2E correctness rests on `just restore`, which imports a
committed dump **without** `ON_ERROR_STOP` (finding **F8**,
`02-data-model.md` §9). A partially-failed restore produces a half-seeded
database, and the resulting Playwright failures would look like application
bugs.

## Open questions

1. §2 — why were the `integrations`, `broker`, `api` and `grantmakers` test
   invocations commented out? Flaky, slow, or superseded?
2. §3 — was `test_rls.py` intended to be a pytest suite, or deliberately a
   manual diagnostic?
3. §6 — is there an appetite for a coverage gate, or at least a reported
   figure, on `foundational`?
4. §7 — should `@foundational/core` have unit tests, given it holds the BFF
   query layer?
5. §4 — has the suite's runtime been a problem before? (`pyleak`, the
   profiler and `just timetests` suggest so.)
