<!-- reviewed at commit 58fbc761 on 2026-10-06 -->
# Session: initial repo survey (orientation only, no findings)

Clone: `sportsengland/InvestmentSystem`, branch `main`, HEAD `58fbc761`
("CI build fix (#410)", 2026-10-06). Not shallow; 511 commits.

## Workspace actions
- Created `docs/sportsengland/InvestEngland/00-index.md` (only missing item).
- All other required folders already existed.

## Purpose [verified]
Grant/investment management system for Sport England, codename **Arena**
(README.md:1-7). Two audiences: public applicant portal (`grantseekers`) and
staff back-office (`grantmakers`).

## Stack [verified]
- Frontend: React 19 + React Router 7 (framework mode; README calls it Remix),
  TypeScript, Tailwind 4, Vite 7, pnpm 10 workspaces, Playwright + Vitest.
- Backend: Python 3.12, Poetry, `unrest` (vendored, Starlette + asyncpg),
  Postgres 16, Redis, Caddy 2.9 gateway.
- Vendored framework: `backend/vendor/unrest` (develop-mode path dep).

## Entry points [verified]
| Service | Entry | Image target |
|---|---|---|
| api | `backend/api/app.py` (`unrest.Server`) | `foundational_api` |
| integrations | `backend/integrations/integrations.py` | `foundational_integrations` |
| broker | `backend/broker/broker.py` (cmd `broker`) | `foundational_broker` |
| scheduler | same broker code, cmd `scheduler` | `foundational_scheduler` |
| migrations | `backend/sql/pgutil` | `foundational_migrations` |
| grantseekers | `frontend/grantseekers/app/root.tsx`, port 8001 | `foundational_grantseekers_prod` |
| grantmakers | `frontend/grantmakers/app/root.tsx`, port 8002 | `foundational_grantmakers_prod` |

`backend/app.py` is a 0-byte file [verified] — purpose unknown [assumed: dead].

## Size [verified]
975 tracked files. ~237k lines across py/ts/tsx/sql/md/css/js.
- `backend/sql` 141,650 lines / 29 files — but ~124k of that is generated
  `export/**/data.sql` dumps; 19 hand-written migrations.
- `backend/foundational` 45,748 / 161 — the real backend core.
- `frontend/grantmakers` 40,638 / 315 (105 routes).
- `frontend/grantseekers` 24,211 / 187 (86 routes).
- `frontend/foundational` 7,593 / 81; `backend/integrations` 9,266 / 35;
  `backend/api` 5,232 / 25; `backend/broker` 3,232 / 6; `backend/vendor` 6,104 / 26.

## Tests present [verified]
- Python: 57 test files, nearly all in `backend/foundational/tests`
  (domain-level: payments, ledger, RLS, KYC, roles, workspaces...).
  `backend/api/tests` has exactly one file; `backend/integrations/tests` has 7.
- TypeScript: 55 unit/spec files, all under `grantmakers` (~30) and
  `grantseekers` (~7) — none in `frontend/foundational`.
- E2E: Playwright, 11 specs in grantmakers, 10 in grantseekers.
- CI `just ci-test` runs only `api/entrypoint.sh test`; the grantmakers line
  is commented out (justfile:211-213).

## Recent activity [verified]
First commit 2025-08-07. 29 commits in last 30d, 64 in last 90d.
By month: 2026-01 68, 02 85, 03 84, 04 44, **05 and 06 absent**, 07 12,
08 22, 09 23, 10 8. 12 authors across three supplier domains
(jamescharlesconsulting.com, redrockconsulting.co.uk, empyreandigital.com).
Work is ticket-driven (`ARENA-nnn`) via PRs; ~20 live remote feature branches.

## Deployment [verified]
Azure Container Apps. `.github/workflows/main.yml` triggers on tags matching
`dev-*`, `uat-*`, `test-*`, `live-*`: test -> build/push 7 images to Azure ACR
-> `az containerapp update` per service -> run migrations as a container job.
`demo.yml` and `restore.yml` are manual `workflow_dispatch` for dev.
`test.yml` runs on every branch push (unit + frontend + Playwright).
A separate legacy path exists: `just deploy` scp/ssh's a tarball to a single
VM and runs `demo.sh` [verified in justfile:142-175] — the demo environment
[assumed].
Secrets are git-crypt encrypted under `secrets/` and `backend/tenants/`
(.gitattributes); config arrives as a docker secret mounted at `/host/.env`.

## Third-party integrations [verified]
Creditsafe (AML); NetSuite + a `sportengland` finance impl; ActivePlaces, Esri,
OS Places (geo); Companies House, Charity Commission, SIC codes, 360Giving
(KYB); Credas, Stripe Identity (KYC); Experian, PTX (payments).

## Notable for later review (not yet findings)
- Three committed Postgres data dumps totalling ~73 MB: `export/data.sql` and
  `export/demo/data.sql` are both exactly 23,901,875 bytes but differ in
  content (md5 9f34b05e... vs 2534197c...); `export/scenarios/data.sql` is
  25,766,945 bytes. Same-size-different-content suggests the same dump
  regenerated, not a copy. Four identical `schema.sql` copies sit beside them.
- `main.yml` and `demo.yml` set `continue-on-error: true` on the test step for
  tagged builds, so a tagged deploy proceeds with failing tests.
- README documents a `backend/scheduler` directory that does not exist.
- Repo naming mismatch: clone `InvestmentSystem` vs engagement doc `InvestEngland`.
