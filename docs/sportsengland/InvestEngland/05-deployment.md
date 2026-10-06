<!-- reviewed at commit 58fbc761 on 2026-10-06 -->
# InvestEngland — build and deployment

Scope: how code reaches an environment, how configuration and secrets get there,
what is reproducible, and what the release gate actually enforces. Claims are
`[verified]` or `[assumed]`.

**A limit worth stating up front.** There is **no infrastructure-as-code in the
repository** [verified] — no Terraform, Bicep, or ARM templates. Everything
below is read from the GitHub workflows, the Dockerfiles, `docker-compose.yml`
and the `justfile`. The Azure side (ingress rules, scaling, the container-app
job's configured arguments, environment variables) is invisible from here, and
several questions can only be answered in the Azure portal.

## What matters here

1. **Migrations never run on a `live-*` deploy.** The `db-migrations` job's
   condition lists `dev-`, `uat-` and `test-` only — production image deploys
   complete successfully with the schema untouched and nothing signalling it
   (§3.2).
2. **Migrations run *after* the new code is live**, in every environment that
   does run them — so there is always a window where new code meets the old
   schema (§3.2).
3. **The release gate is open**: every `main.yml` run is tag-triggered, and the
   tagged test step is `continue-on-error` (§3.1, finding **F3**).
4. **Configuration is gated on a string the codebase says is wrong** — finding
   **F1**, the review's top item (§5).

## 1. Build

Two Dockerfiles, seven images, all multi-stage with shared base layers
[verified].

**Backend** (`backend/Dockerfile`) — one `foundational_backend` base installs
system libraries (`postgresql-client`, plus Cairo/Pango/GLib/FFI for
WeasyPrint) and the `foundational` + `vendor` + `tenants` trees, then five thin
targets add one service each:

| Target | Adds | Entry |
|---|---|---|
| `foundational_api` | `api/` | `api/entrypoint.sh run` |
| `foundational_integrations` | `integrations/` | `integrations/entrypoint.sh run` |
| `foundational_broker` | `broker/` | `broker/entrypoint.sh broker` |
| `foundational_scheduler` | `broker/` (same code) | `broker/entrypoint.sh scheduler` |
| `foundational_migrations` | `sql/` | `sql/pgutil status` |

**Frontend** (`frontend/Dockerfile`) — an `install` stage runs
`pnpm install --frozen-lockfile`, a `production` stage runs `pnpm run -r build`
then `pnpm deploy --prod` per app, and two `*_prod` targets copy only the
deployed output. Development targets run `pnpm -F <app> dev` against the same
`install` layer, which is what the local compose file uses [verified].

Reproducibility is good: frozen lockfile on the frontend, lockfile-driven
Poetry on the backend (`04-dependencies.md` §3), no `:latest` base images —
`python:3.12-slim`, `node:22-alpine`, `postgres:16`, `caddy:2.9-alpine`,
`redis` [verified]. `redis` is the one unpinned image tag, in
`docker-compose.yml` only, so it affects local development rather than
production [verified].

One subtlety: `NODE_OPTIONS="--max-old-space-size=4096"` is set on the
production build stage [verified], which says the build has previously run out
of memory. Worth remembering if the frontend grows.

## 2. Environments

Four named environments, driven entirely by git tag prefix [verified:
`.github/workflows/main.yml:3-5`]:

```
tag push: dev-*  uat-*  test-*  live-*
              │
              ▼
          test ──▶ push-image (7 images to Azure ACR) ──▶ deploy ──▶ db-migrations
                                                                      (not for live-*)
```

GitHub `environment:` is resolved from the tag name with a single chained
expression (`main.yml:145`, repeated at `:223`). I traced it rather than trusting
it: for `dev-310-20261006` it yields `dev`, for `uat-*` `uat`, for `test-*`
`test`, for `live-*` `live` — correct in every case the trigger admits
[verified by hand-evaluating the `&&`/`||` precedence]. It has one latent
fragility: the first clause is `github.ref_name == 'dev'`, which returns the
boolean `true` rather than the string `'dev'`. A tag named exactly `dev` would
resolve the environment to `true`. The `on.push.tags` globs (`dev-*` etc.)
cannot match a bare `dev`, so this is unreachable today — but it is a 7-clause
expression doing work that a 4-line `case` or a mapping would do legibly.

Recent tags confirm the scheme in use: `dev-310-20261006-2`, `dev-20261005`,
`test-rls-v0.6.0`, `dev-324-20260913` [verified from `git tag`]. Note
`test-rls-v0.6.0` matches `test-*` and would therefore have triggered a full
test-environment deploy — tag naming and deployment triggering are coupled, so
a tag created for bookkeeping deploys something.

Two manual workflows exist, both hardcoded to `dev`: `demo.yml`
(build + push + deploy + restore) and `restore.yml` (restore only), each
`workflow_dispatch` [verified].

## 3. The release pipeline

### 3.1 The test gate is open — F3

`main.yml` has two test steps [verified: `:24-33`]:

```yaml
- name: Run tests with continue-on-error (tagged)
  if: ${{ startsWith(github.ref, 'refs/tags/') }}
  continue-on-error: true
  run: just ci-test

- name: Run tests without continue-on-error (non-tagged)
  if: ${{ !startsWith(github.ref, 'refs/tags/') }}
  run: just ci-test
```

The workflow triggers **only** on tags. So the second step is dead and the first
always runs with `continue-on-error: true`. `continue-on-error` marks the step
failed but the **job** successful, so `push-image`'s `needs: [test]` and
`if: success()` are both satisfied and the deploy proceeds [verified].

**The path to production has no test gate.** `demo.yml:24-28` repeats the
pattern. This is finding **F3**.

Mitigating context, which matters for the rating: `test.yml` runs on
**every branch push** (`branches: ['**']`) and runs more than the deploy
workflow does — backend tests, frontend unit tests, and both Playwright suites,
with report artefacts on failure [verified]. So the code is tested, usually
before tagging. What is missing is the gate at the moment of release. The fix is
to delete `continue-on-error` for `live-*` at minimum; if tagged runs are flaky
for environmental reasons, quarantine those tests rather than the gate.

### 3.2 Migrations: skipped for live, and late everywhere else

Two separate problems in one job.

**(a) `live-*` is excluded.** The `db-migrations` job condition
(`main.yml:209-218`) [verified]:

```yaml
db-migrations:
  needs: [deploy]
  if: |
      success() &&
      (
      startsWith(github.ref, 'refs/tags/dev-') ||
      startsWith(github.ref, 'refs/tags/uat-') ||
      startsWith(github.ref, 'refs/tags/test-')
      )
```

`live-` is absent. The `deploy` job *does* update the migration job's image for
live (`az containerapp job update`), but nothing ever starts it. So a `live-*`
tag deploys seven new images and leaves the production schema untouched, and the
workflow goes green.

If that is deliberate — production migrations applied by hand, under change
control, which is a legitimate choice for a system holding grant records — then
the workflow should **say so**, and ideally fail or warn rather than silently
skipping. As written, the only way to know is to read the `if` block. Code that
needs migration 111 can be tagged `live-…`, deploy cleanly, and fail at runtime
against a schema that stops at 110.

**(b) Migrations run after the code.** Where the job does run, the order is
`push-image → deploy → db-migrations` [verified from `needs:`]. New containers
are serving traffic before the schema changes. For an additive migration that is
a window of errors; for anything else it is worse. The conventional order is
migrate-then-deploy with backwards-compatible migrations (expand/contract).

**(c) What the job actually does is invisible from here.** `main.yml` starts it
with no arguments — `az containerapp job start --name $MIGRATIONS_JOB_NAME` —
so it runs whatever args the job is configured with in Azure. The migration
image's `CMD` is `["status"]`, which is read-only. But `demo.yml:201` and
`restore.yml:23` start the same job with `--args "restore"`, and `restore` in
`pgutil` **drops and recreates the database** before re-importing a dump
(`sql/pgutil:266-275`) [verified]. Both of those are pinned to the `dev`
environment, so the destructive path is scoped — but whether the live job is
configured as `apply`, `status` or `restore` cannot be determined from the repo.

**Question for the team, and it is urgent-adjacent:** what arguments is the
live `MIGRATIONS_JOB` configured with? If the answer is `restore`, a `dev-`
tagged deploy to the wrong environment destroys data.

### 3.3 Image tagging and rollback

Images are tagged with `${{ github.ref_name }}` — the full tag name — so each
deploy has a unique immutable image reference [verified]. That is better than
`latest` and gives real traceability from a running container back to a commit.

There is no rollback workflow. Rolling back means re-running
`az containerapp update` with an earlier tag by hand, or using Container Apps'
revision history. Given §3.2(a), a rollback that crosses a migration boundary
has no automated path at all. For a system that moves public money, a documented
and rehearsed rollback is worth more than most of the Medium findings in the
review.

## 4. The second deployment path

A complete, separate deployment mechanism exists in the `justfile` and is not
part of CI [verified: `justfile:142-180`]:

```
just push    → docker push to $PRIVATE_DOCKER_REPO
just deploy  → tar up secrets/ + backend/sql/ + gateway/ + docker-compose.yml
             → scp to $DEPLOYED_VM_USER@$DEPLOYED_VM_DOMAIN
             → ssh "sh demo.sh restart"
```

This targets a single VM, substitutes `Caddyfile.demo` for the local
`Caddyfile`, and ships only `secrets/demo.env`. `Caddyfile.demo` reveals the
target: `theframe.uksouth.cloudapp.azure.com`, behind HTTP basic auth with the
credentials in a comment — "Username `demo`, password `sportengland`"
(`gateway/etc/caddy/Caddyfile.demo:9-11`) [verified].

So there are two deployment models: Container Apps for dev/uat/test/live, and a
hand-driven single VM for the demo environment, with its own secrets file, its
own gateway config, and a shared password committed in a comment. The basic-auth
credential is not protected: `.gitattributes` encrypts only `secrets/**` and
`backend/tenants/**`, and `Caddyfile.demo` lives under `gateway/`, so the bcrypt
hash and the plaintext comment sit in cleartext in the repository — confirmed by
reading the file straight out of the clone [verified].

That is defensible for a demo site whose purpose is to be shown to people, and
the gateway comment is explicit that the point is to keep "Internet randos and
internal staff" out rather than to secure anything. But it should be stated:
**the demo environment's password is public to anyone with repository access**,
and the demo site runs the same application code, pointed at `demo.env`.

**Question:** is the demo VM still in use, and does it hold any real data? If it
is retired, deleting `just deploy`, `demo.sh` and `Caddyfile.demo` removes a
whole second deployment surface from the review.

## 5. Configuration and secrets

**Delivery.** Secrets are git-crypt encrypted at rest under `secrets/` and
`backend/tenants/` (`.gitattributes`), unlocked with a GPG key or a symmetric
key via `bin/unlock`. In CI, `bin/unlock "${{ secrets.GIT_CRYPT_KEY }}"` runs as
the first step of every workflow that builds [verified]. Locally and in compose,
the decrypted `secrets/${ENVIRONMENT}.env` is mounted as a Docker secret at
`/host/.env` and sourced by each `entrypoint.sh` [verified].

git-crypt is a reasonable choice for this shape of problem — it keeps
infrastructure and third-party credentials versioned alongside the code that
needs them, with per-developer GPG access. Two properties to be aware of:
revocation is not retroactive (a removed collaborator can still decrypt history
they already had), and `GIT_CRYPT_KEY` in GitHub Actions is a single symmetric
key that unlocks everything.

**Reading.** `config.get(key)` reads `os.environ` and **raises** on a missing
variable unless a default is passed (`vendor/unrest/unrest/contexts/config.py:33-40`)
[verified]. Fail-fast on missing config is the right default. The frontend
mirrors it with `getEnvOrThrow` [verified].

**The environment string — F1.** This is the review's top finding and it belongs
to this document. `is_production()` is `get("ENVIRONMENT") == "production"`,
while three comments in three files state Azure sets `ENVIRONMENT=live`
including on live itself (`01-architecture.md` §4.1 has the detail and the
citations). The team's response was to add a *second* variable, `ARENA_TIER`,
with `is_internal_tier()` / `is_live_tier()` helpers, and to migrate the
OTP-bypass and email-whitelist gates onto it — the comment on
`INTERNAL_ARENA_TIERS` even says "Missing/unknown fails safe" [verified]. That
is exactly right.

What was left behind on the old variable is the demo-endpoint registration and
the API documentation routes. So the configuration story is a half-completed
migration: a known-bad signal, a known-good replacement, and two consumers still
on the bad one — both of which fail *open*.

The deployment-level recommendation is narrow: **set `ENVIRONMENT=production`
in the live environment, or move the two remaining consumers onto `ARENA_TIER`
with a positive allowlist.** The second is better, because it fails closed.
Either way, confirm the live values first (assumption **A1**).

## 6. Observability and health

Every service exposes `/healthcheck` unauthenticated, returning
`{"status": "ok"}` [verified: `api/endpoints/__init__.py:70`,
`integrations.py:66`]; the frontends expose a route of their own
(`frontend/foundational/.server/health.ts`). These are liveness checks only —
none touches the database or Redis, so a service with a dead connection pool
still reports healthy.

`docker-compose.yml` defines a real healthcheck for Postgres (`pg_isready`,
with `depends_on: service_healthy` gating migrations and the api) [verified].
No other compose service has one, and the application services use
`depends_on: service_started`, so compose ordering is start-ordering rather
than readiness-ordering — hence the README's caveat that `just restore` must be
run before login flows work.

Logs are structured JSON to stderr with request context and user identity on
every line (`01-architecture.md` §8), which is the right shape for Container
Apps log ingestion. There is no metrics endpoint, no tracing, and no error
tracker (no Sentry or equivalent) anywhere in the repo [verified]. For a system
with 13 scheduled jobs and a payment pipeline, the absence of job-level alerting
is notable — though the application does have its own `panic_attacks` mechanism
for domain-level alarms (`02-data-model.md` §7), and one scheduled job exists
specifically to alert admins when ledger exports fail.

## Open questions

1. §3.2(a) — is skipping migrations on `live-*` deliberate? If so, what is
   the manual process, and can the workflow fail loudly instead of silently?
2. §3.2(c) — what arguments is the live `MIGRATIONS_JOB` configured with in
   Azure? `restore` would be destructive.
3. §5 — what are `ENVIRONMENT` and `ARENA_TIER` set to in each deployed
   environment? (Assumption **A1**; gates finding **F1**.)
4. §3.3 — is there a rollback procedure, and has it been rehearsed across a
   migration boundary?
5. §4 — is the demo VM still live, and does it hold real data?
6. §2 — is the API Container App's ingress external or internal-only?
   (Assumption **A2**; bounds **F1**.)
