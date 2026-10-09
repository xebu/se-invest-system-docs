<!-- reviewed at commit 58fbc761 on 2026-10-06 -->
# Architecture views

Conceptual diagrams of the Sport England Investment System, generated from the
reference docs in this repository. They are intended for onboarding, review and
stakeholder walkthroughs — **not** as authoritative deployment or
infrastructure diagrams.

**Provenance.** These were produced by ChatGPT from `00-index.md`,
`01-architecture.md` and `02-data-model.md`. The model read those documents,
not the codebase. Every claim in them therefore inherits whatever was correct
in the source docs, and anything the source docs did not cover was filled in by
inference. The accuracy check below is the result of taking each diagram back
to the code.

| File | Covers | Status |
|---|---|---|
| `review-method.png` | The review itself: inputs, method, verification loop, artifacts | **accurate** — used as the README header |
| `release-pipeline.png` | Tag-triggered deploy to Azure Container Apps, and findings F3 / F20 / F21 | **accurate** — one presentational issue, see below |
| `application-lifecycle.png` | The ten stored statuses, staff vs applicant labels, and the derived award states | **accurate** but for one garbled arrow label, see below |
| `request-data-flow.png` | Read/write paths, async runtime, integrations, providers | **accurate** |
| `tenant-auth-rls-flow.png` | Authentication, tenant resolution, both DB roles, RLS enforcement | **accurate** — see below |
| `combined-request-and-tenant-security.png` | Both of the above, as a single two-panel view | **top panel accurate; bottom panel has errors — see below** |
| `architecture-summary.md` | Written analysis accompanying the diagrams | accurate as a summary of docs 00–02 |

---

## Accuracy check

### `review-method.png` — accurate

Checked figure by figure: 975 tracked files, ~108,000 hand-written lines, 19
migrations, 59 tables, commit `58fbc761`; 7 reference documents, 34 findings at
1 Critical / 8 High / 17 Medium / 8 Low, 1 executable reproduction, 2 session
notes. The three footer items are findings **F22**, **F5** and **F1**, each
stated correctly.

Worth noting *why* this one is clean. It was generated from a prompt carrying
every figure and claim explicitly, rather than from prose it had to interpret.
Nothing was left for it to fill in, and nothing was invented. That is the same
mechanism, run with better inputs, that produced the Keycloak error below.

Checked against the code at `58fbc761`, because a diagram is quoted far more
often than the document it came from.

### `application-lifecycle.png` — accurate but for one arrow label

Verified against `frontend/foundational/utils/application-status.ts` and the
transition functions in `entities/{applications,assessments,decisions}.py`: all
ten state codes; all twenty staff/applicant labels; the five-stage grouping;
every transition including `contested → accepted|rejected`; `approve()` drawn
as one function with two outcomes (`accepted → approved`, `rejected → denied`,
guarded at `decisions.py:137-140`); the seven states collapsing to the single
applicant label "In Assessment"; all seven derived award mappings; and the
naming trap separating stored `rejected` from stored `denied`.

**The one defect:** the arrow from `discommended` to `accepted` is labelled
`rccept()`. It should be `accept()`. The destination card is plainly titled
`accepted`, so the structure is not in doubt — it is a cosmetic blemish on one
label.

**Why it was left.** That single label took four values across four
regenerations — `cocept()`, then correctly `accept()`, then `reject()`, then
`rccept()` — each time as collateral from fixing something else. See below.

### What four rounds of correction cost

This diagram is the clearest record in the repository of what iterating on a
generated image actually involves. Each round fixed what was asked and broke
something that had been right:

| Round | Fixed | Broke |
|---|---|---|
| 1 | — | Arrows drawn as a linear chain; `cocept()` typo; band enclosed 6 of 7 |
| 2 | Arrows, band, typo | `rejected` relabelled DE04 (it is DE02, and DE04 is `denied`) |
| 3 | `rejected` code | `discommended → accepted` relabelled `reject()` |
| 4 | Stray full stop | Same label again, now `rccept()` |

Two things follow, and both are worth stating to anyone judging this method:

1. **Targeted edits do not localise.** Every round must be re-checked in full,
   not at the point of change. The round-2 regression — two cards sharing the
   code DE04 — would have gone unnoticed by anyone checking only the arrows
   they had just asked to fix, and it directly undermined the naming-trap
   callout beside it.
2. **There is a point where another round is a bad trade.** By round four the
   remaining defect was one character on one label, while each round carried a
   demonstrated risk of a new error elsewhere. Stopping is the correct move;
   the blemish is cheaper than the risk.

### `release-pipeline.png` — accurate, with one presentational issue

Verified: the trigger globs; all seven ACR image names exactly
(`frontend-external`, `frontend-internal`, `backend-api`,
`backend-integrations`, `backend-broker`, `backend-scheduler`,
`database-migrator`); the dead untagged test step and the
`continue-on-error` mechanism by which a failed step still passes the job
(**F3**); the `db-migrations` condition omitting `live-` (**F20**); the
deploy-before-migrate ordering (**F21**); and the side note that a separate
workflow tests every branch push.

**Presentational issue — the icons invert the message.** The `test` card marks
the *tagged* branch with a green tick and the *untagged* branch with a grey
cross. Read as "which branch runs", that is correct. Read as "which branch is
healthy" — the more natural reading on a diagram titled *"where it leaks"* —
it is backwards: the ticked branch is the one that lets failing tests through.
Swapping the tick for a warning glyph would fix it.

**Small omission.** The deploy job makes eight `az containerapp` calls, not
seven: the seven service updates shown, plus `az containerapp job update` for
the migration job (`main.yml:204`). Worth knowing because it sharpens F20 — on
a `live-` deploy the migration job's *image* is updated and the job is then
never *started*, which reads more like an oversight than a deliberate
hold-back.

### `request-data-flow.png` — accurate

Verified: the BFF read path uses a separate read-only credential while
mutations go through the API (`01-architecture.md` §3); the integrations
service is reached either in-process or by proxy (§6); Redis/Taskiq carries
background work to a worker running the same image (§7); the provider list
matches `backend/integrations/implementations/`.

Its callout — *"the database schema is effectively a frontend interface because
BFF reads can bypass the API entirely"* — is a fair statement of finding **F6**.

### `tenant-auth-rls-flow.png` — accurate

Third revision, and the only one of the three that is clean.

Verified panel by panel: the two authentication paths (applicants on email plus
a one-time code with an API-issued JWT signed by a per-tenant secret; staff on
**Azure External ID**, `login.microsoftonline.com`, staff portal only);
**header-first tenant resolution** — `X-API-Key`, else the `X-Tenant-Domain`
header forwarded by the frontend, resolved *before* the JWT is read, with the
JWT's tenant claim then compared against it to detect a mismatch
(`backend/api/endpoints/auth.py:40-56`); **both** database roles, BFF on
`POSTGRES_QUERY_URI` / `readonly_access` and API on `POSTGRES_MUTATE_URI` /
`readwrite_access` (`vendor/unrest/unrest/db/pool.py:106,114`;
`frontend/foundational/.server/configuration.ts:31`);
`set_config('rls.tenant'|'rls.owner', …, false)` with the `is_local = false`
consequence spelled out (`.server/db.ts:25-26`); and the view-bypass caveat,
finding **F2**, confirmed by execution — see `verification/`.

One imprecision worth knowing, not worth another round: panel 5 attributes
`set_config` to both services. That is the **BFF's** mechanism. The backend
issues plain `SET rls.tenant = '…'` (`vendor/unrest/unrest/db/pool.py:67,69`).
Both are session-scoped, so the effect the diagram describes is right for both
paths; only the function name is BFF-specific.

#### What three rounds cost

| Round | Fixed | Broke |
|---|---|---|
| 1 | — | Keycloak at a fabricated domain; `app.current_tenant`/`app.current_user`; no view caveat |
| 2 | All three | `set_config(…, true)` — should be `false` |
| 3 | `false` | Tenant resolution redrawn as coming from JWT claims; "Single database role" |
| 4 | Both regressions | nothing |

Round 3 is the one to note. The request was a **single character** — `true` to
`false`. What came back was a redesign that fixed it and silently dropped two
verified facts: the header-based tenant resolution and the read-only/read-write
role split. Neither was mentioned in the request, and both had been correct in
the previous revision.

The lesson is the same one the lifecycle diagram taught, and it is the single
most useful thing to know about iterating on generated images: **the size of
the request does not predict the size of the change.** Re-check the whole
artefact every round, or do small text fixes by hand.

### `combined-request-and-tenant-security.png` — bottom panel is wrong

The top panel ("Request / data flow") is accurate, including the service ports
(api 8080, integrations 8081).

The bottom panel ("Tenant / auth / RLS flow") contains three errors. They are
listed here rather than quietly fixed because the diagram is useful and the
errors are instructive about where generated documentation drifts.

**1. Keycloak is not the identity provider.** The panel shows
*"Keycloak (auth.investengland.org.uk)"* issuing OIDC tokens. There is no
Keycloak anywhere in the repository and no such domain. The real picture:

- The primary authentication path is **email plus a one-time code** —
  `/login`, `/verify`, with the API issuing a JWT signed with a per-tenant
  secret (`backend/foundational/foundational/authn.py`).
- **Staff SSO** exists and is **Azure External ID**, not Keycloak —
  `login.microsoftonline.com` (`backend/foundational/foundational/sso.py:16`,
  `frontend/grantmakers/app/routes/sso.login.tsx:23`). It is `grantmakers`-only.

**2. The RLS session variables are wrong.** The panel shows
`SET LOCAL app.current_tenant` / `app.current_user`, and lists
`app.current_tenant`, `app.curent_user` *(sic)* as the policy context. The
actual names are **`rls.tenant`** and **`rls.owner`**, set via `set_config`.
`app.current_tenant` and `app.current_user` appear **zero** times in the
repository. Note the second name is not just differently spelled but
differently *scoped*: the real variable is the **owner** (an organisation),
not the user.

**3. It asserts isolation without the caveat.** The panel states *"Both API and
direct reads (from BFFs) use the same RLS rules."* That holds for tables and
**fails for views** — finding **F2**, verified by execution. The companion
diagram carries this caveat; this one drops it, which inverts the conclusion on
the one point that matters most.

### What this illustrates

All three errors share a cause: the generating model had the documents but not
the code, so where the docs were silent it produced plausible, conventional
answers. Keycloak is the default assumption for "identity provider";
`app.current_tenant` is the conventional name for an RLS session variable.
Both are what a well-built system of this shape *usually* does. Neither is what
this one does.

That is the practical limit of generated documentation, and the argument for
the `[verified]` / `[assumed]` labelling used throughout this repository: a
diagram cannot show its own confidence, so it reads as uniformly authoritative
whether or not it was checked.

**Status:** superseded. `tenant-auth-rls-flow.png` is the corrected second
revision and covers the same ground properly. This file is kept only as the
worked example of the drift described above — it should not be used as
reference documentation. Delete it if the illustration is not wanted.
