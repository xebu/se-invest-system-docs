<!-- reviewed at commit 58fbc761 on 2026-10-06 -->
# InvestEngland — dependencies

Scope: what the system depends on, how tightly it is pinned, how reproducible a
build is, maintenance and licensing posture. Claims are `[verified]` or
`[assumed]`.

**A limit worth stating up front.** Assessing *currency* — how far behind latest
each package is — requires querying package registries, which I have not done
from this read-only clone. Everything below is resolved-version fact from the
committed lockfiles plus pinning-style analysis. Where I say a package looks
held back, that is from an exact pin or a capped range visible in the manifest,
not from a registry comparison. The one action this document cannot complete is
`poetry show --outdated` and `pnpm outdated`; see §6.

## What matters here

1. **No dependency automation at all** — no Dependabot, no Renovate, and the
   `update-poetry` recipe deliberately updates only the two local path
   dependencies, never third-party ones (§4).
2. **Lockfiles are committed and install flags are mostly frozen**, so builds
   are reproducible. The frontend is strict everywhere; the backend relies on
   Poetry's default lock behaviour rather than an explicit flag (§3).
3. **Two exact pins and one capped range** mark where upgrades are being
   actively avoided: `weasyprint 62.3` / `pydyf 0.11.0` as a pair, and
   `stripe ^11` (§2.1).

The posture is better than "no automation" suggests: the resolved lockfile
contents are recent, so someone has been re-locking.

---

## 1. Inventory

| | Direct | Resolved (lockfile) |
|---|---|---|
| Python — `foundational` (incl. dev) | 26 (13 runtime + 13 dev) | 109 |
| Python — vendored `unrest` (incl. dev) | 24 (17 runtime + 7 dev) | — |
| Node — root devDependencies | 39 | 1,142 |
| Node — `grantmakers` | 34 + 4 dev | — |
| Node — `grantseekers` | 29 + 4 dev | — |
| Node — `@foundational/core` | 4 | — |

[verified by counting manifest entries and `[[package]]` / `resolution:` blocks
in `backend/foundational/poetry.lock` and `frontend/pnpm-lock.yaml`.]

`backend/api` declares only 2 dependencies — `foundational` (path) and
`cloudpathlib` — which is the manifest-level evidence for how thin the transport
layer is [verified].

Runtime floors: `foundational` and `unrest` both declare `^3.11` while
`backend/api` requires `^3.12` and the image is `python:3.12-slim` [verified].
The effective floor is therefore 3.12; the two `^3.11` declarations are looser
than anything that is actually built, which would matter only if the libraries
were consumed elsewhere.
Node is `>=22.0.0` with `.nvmrc` = `22` — major only, so the minor and patch
float [verified]. pnpm is pinned exactly via `packageManager: pnpm@10.15.0`
and `engines.pnpm: ">=10.0.0 <11.0.0"` [verified] — the strictest version
constraint in the repo, which is a nice touch since pnpm's resolution behaviour
is itself build-affecting.

## 2. Pinning style

Essentially everything is a **caret range** — floating within the semver major
— backed by a committed lockfile. That is the mainstream choice and it is
applied consistently.

### 2.1 The exceptions

Three deviations, and each tells you something [verified:
`backend/foundational/pyproject.toml:14-20`]:

```toml
weasyprint = "62.3"     # exact
pydyf      = "0.11.0"   # exact
stripe     = "^11.3.0"  # capped at major 11
```

`weasyprint` and `pydyf` pinned exactly, together, is the signature of a known
incompatibility — WeasyPrint's PDF backend is `pydyf`, and the two have had
breaking interactions. The pin is almost certainly deliberate and correct
[assumed — there is no comment explaining it, which is the actual problem].
WeasyPrint renders the award agreements and offer letters
(`foundational/infra/documents.py`, `tenants/*/templates/documents/`), so this
pin sits on the document-generation path.

`stripe` capped at major 11 (resolved 11.6.0) holds back a provider SDK on the
identity-verification path.

**Recommendation:** add a one-line comment to each pin saying why. An
unexplained exact pin is indistinguishable from neglect six months later, and
the next person to run `poetry update` has no way to know whether lifting it is
safe.

### 2.2 Resolved versions on the security-relevant path

From `poetry.lock` [verified]:

| Package | Resolved | Package | Resolved |
|---|---|---|---|
| `cryptography` | 46.0.5 | `starlette` | 0.51.0 |
| `pyjwt` | 2.11.0 | `uvicorn` | 0.40.0 |
| `certifi` | 2026.2.25 | `asyncpg` | 0.31.0 |
| `urllib3` | 2.6.3 | `pydantic` | 2.12.5 |
| `requests` | 2.32.5 | `httpx` | 0.28.1 |
| `h11` | 0.16.0 | `jinja2` | 3.1.6 |
| `bcrypt` | 4.3.0 | `python-multipart` | 0.0.21 |
| `boto3` | 1.42.56 | `taskiq` | 0.11.20 |
| `markdown` | 3.10.2 | `taskiq-redis` | 1.1.2 |
| `weasyprint` | 62.3 (pinned) | `stripe` | 11.6.0 (capped) |

`certifi 2026.2.25` dates the last full re-lock to late February 2026 or after
[verified] — seven months before this review but not stale. `cryptography 46`,
`pyjwt 2.11` and `urllib3 2.6.3` are all recent majors. The crypto and TLS
surface is in reasonable shape.

One laggard stands out: **`python-json-logger` is at 2.0.7**, constrained by
`unrest`'s `^2.0.7` which cannot reach the 3.x line [verified]. 2.0.7 predates
that package's maintainership transition. It is the formatter for every log line
the backend emits (`01-architecture.md` §8), so it is load-bearing for
observability but not security-sensitive. Fixing it means editing the vendored
`unrest` manifest — see §5.

## 3. Build reproducibility

Both lockfiles are committed: `poetry.lock` (lock-version 2.0) and
`pnpm-lock.yaml` (lockfileVersion 9.0) [verified].

Install flags [verified by grepping every install invocation]:

| Where | Command | Frozen? |
|---|---|---|
| `frontend/Dockerfile:10` | `pnpm install --frozen-lockfile` | **yes** |
| `justfile:138,207,220` | `pnpm install --frozen-lockfile` | **yes** |
| `.github/workflows/test.yml:40` | `pnpm install --frozen-lockfile` | **yes** |
| `backend/Dockerfile:20` | `poetry install --no-root` | implicit |
| `backend/{api,integrations,broker}/entrypoint.sh` | `poetry install --no-root` | implicit |
| `justfile:98` | `poetry install --no-root` | implicit |

The frontend is unambiguous — six invocations, all frozen, so a drifted
lockfile fails the build rather than silently resolving something new.

The backend relies on Poetry's default behaviour: `poetry install` does install
from `poetry.lock` when present, and modern Poetry errors if the lock is
inconsistent with `pyproject.toml`. So it is reproducible in practice, but by
convention rather than assertion. There is no backend equivalent of
`--frozen-lockfile` in use, and no CI step that verifies lock freshness.

**Recommendation:** add `poetry check --lock` (or `poetry install --sync`) to
CI so a hand-edited `pyproject.toml` without a re-lock fails fast. Cheap, and it
closes the asymmetry with the frontend.

The frontend Docker build additionally uses a pnpm store cache mount
(`--mount=type=cache,id=pnpm`) [verified] — good for speed, and it does not
affect reproducibility because resolution still comes from the frozen lockfile.

## 4. Maintenance posture

**There is no dependency automation.** `.github/` contains only `workflows/` —
no `dependabot.yml`, and no Renovate configuration anywhere in the repo
[verified].

The one bump mechanism that exists is deliberately narrow
(`justfile:232-236`) [verified]:

```make
update-poetry:
    cd backend/foundational && poetry update unrest && poetry lock
    cd backend/api         && poetry update foundational unrest && poetry lock
    cd backend/integrations && poetry update foundational unrest && poetry lock
    cd backend/broker      && poetry update foundational unrest && poetry lock
```

Every `poetry update` names only `unrest` and `foundational` — the two **local
path dependencies**. No third-party package is ever updated by this recipe. Its
real job is propagating in-repo changes across the four Python projects, which
makes sense given the vendoring (§5), but it means the repo has a tool that
*looks* like dependency maintenance and is not.

Combined with no Dependabot, nothing in this repo systematically surfaces a new
CVE in `cryptography`, `urllib3`, `starlette` or any of the 1,142 resolved npm
packages. That the lockfile contents are nonetheless recent (§2.2) means someone
is doing it by hand, which works until they are on holiday.

**Recommendation:** enable Dependabot or Renovate, grouped (one PR per
ecosystem per week) to avoid noise, with the security-advisory channel enabled
separately so CVEs arrive immediately. Note the interaction with **F3**: until
the release gate is fixed, an automated dependency PR that breaks tests can
still be tagged and deployed.

## 5. The vendored framework

`unrest` is in-repo at `backend/vendor/unrest` and consumed as a develop-mode
path dependency by all four Python projects [verified:
`foundational/pyproject.toml:18`]. This is the single most consequential
dependency decision in the system.

- The vendored copy declares itself **version 0.2.10** [verified:
  `vendor/unrest/pyproject.toml:9`].
- The commented-out upstream pin in `api/pyproject.toml:11` is
  `rev = "v0.1.0"` [verified].

So the in-tree copy is a minor-version line ahead of the pin they would revert
to. Reverting to upstream is therefore not a one-line change — it would need
whatever diverged to be upstreamed first, and nothing in the repo records what
that is. The practical position is that **`unrest` is now first-party code
wearing a dependency's clothes**: 2,223 lines of framework, editable in-tree,
with no upstream relationship that can be re-established cheaply.

That is not necessarily wrong — it is honest about where the framework is
maintained, and it removed a single-maintainer external dependency on
`github.com/workingproof/unrest`. But two consequences follow:

1. It brings its **own 17 runtime dependencies** (`starlette`, `uvicorn`,
   `asyncpg`, `pydantic`, `taskiq`, `taskiq-redis`, `httpx`, `bcrypt`,
   `jinja2`, `mangum`, `python-multipart`, …) [verified], and those are now the
   project's to track. The `python-json-logger` laggard in §2.2 is an example:
   fixing it means editing a vendored manifest, which feels like editing
   someone else's code and so tends not to happen.
2. Its tests do not run. `vendor/unrest/tests/` contains exactly one file,
   `test_routing.py`, with **2 test functions**, and no CI path or `just` recipe
   executes it [verified]. The framework handling routing, auth, serialisation,
   the DB pool and the task queue has 2 tests, neither of which runs — see
   `06-testing.md` §2.

**Question for the team:** is `unrest` intended to return to a pinned upstream
dependency, or is the vendored copy now the real home? The answer changes
whether §5.2 is a gap to fix or an upstream concern.

## 6. Licensing

| Item | Status |
|---|---|
| Repository root | **no `LICENSE` file** [verified] |
| `frontend/package.json` | no `license` field; `private: true` |
| `frontend/grantmakers`, `grantseekers` | no `license` field; `private: true` |
| `frontend/foundational` (`@foundational/core`) | `"license": ""` — present but empty [verified] |
| Vendored `unrest` | **MIT** [verified: `vendor/unrest/LICENSE`] |
| SBOM / licence scanning | none [verified] |

The vendored framework being MIT matters and is the good news: copying it into
the repo is unambiguously permitted, including the right to modify, provided the
copyright notice is retained — which it is.

The gap is the project's own licensing. There is no root `LICENSE`, and the
`private: true` flags are npm publish guards, not a licence grant. For a system
commissioned by a public body from three supplier organisations
(`jamescharlesconsulting.com`, `redrockconsulting.co.uk`,
`empyreandigital.com` — `00-index` / survey), the absence of an explicit licence
or copyright statement is an IP-clarity question rather than a technical one:
who owns this code, and on what terms can Sport England use, modify or re-tender
it? That is a contract question, but the repo should state the answer.

`"license": ""` in `@foundational/core` is worse than absent — an empty string
is a malformed SPDX field that some tooling will read as a declared licence of
no name.

**Recommendation:** add a root `LICENSE` (or an explicit "proprietary — © Sport
England" notice) and either fill or remove the empty field. Add licence scanning
to CI if the engagement has any obligation to report third-party licences; with
1,142 resolved npm packages, nobody knows what is in there by inspection.

## 7. Notable third-party surface

The providers behind the integration interfaces are commercial relationships as
much as dependencies [verified: `backend/integrations/implementations/`]:

| Domain | Providers |
|---|---|
| AML | Creditsafe |
| KYB | Companies House, Charity Commission, SIC codes, 360Giving |
| KYC / IDV | Credas, Stripe Identity |
| Payments | Experian, PTX |
| Finance / ledger | NetSuite, plus a Sport England–specific implementation |
| Geo | OS Places, Esri (Sport England), ActivePlaces |

The architectural seam (`01-architecture.md` §6) means each is swappable by
configuration, which is genuine supply-chain resilience: a provider change is a
config edit plus one new class, not a refactor. Two providers appear twice over
in different roles (Stripe for both identity and payments infrastructure,
Experian and PTX both on the payment path), which is worth knowing for
concentration risk but is a procurement question.

## Open questions

1. §5 — is the vendored `unrest` returning to upstream, or is it now
   first-party? What diverged from `v0.1.0`?
2. §2.1 — why are `weasyprint`/`pydyf` pinned exactly, and `stripe` capped at
   major 11? Can any be lifted?
3. §6 — what is the licensing and copyright position of this codebase, and
   should a root `LICENSE` state it?
4. §4 — is manual re-locking a deliberate choice, or would grouped
   Dependabot PRs be welcome?
5. §6 — does the engagement carry any third-party licence reporting
   obligation that an SBOM would serve?
