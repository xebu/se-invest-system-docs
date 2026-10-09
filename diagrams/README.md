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
| `request-data-flow.png` | Read/write paths, async runtime, integrations, providers | **accurate** |
| `tenant-auth-rls-flow.png` | Authentication, tenant resolution, authorisation, RLS enforcement | **accurate but for one detail** — see below |
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

### `request-data-flow.png` — accurate

Verified: the BFF read path uses a separate read-only credential while
mutations go through the API (`01-architecture.md` §3); the integrations
service is reached either in-process or by proxy (§6); Redis/Taskiq carries
background work to a worker running the same image (§7); the provider list
matches `backend/integrations/implementations/`.

Its callout — *"the database schema is effectively a frontend interface because
BFF reads can bypass the API entirely"* — is a fair statement of finding **F6**.

### `tenant-auth-rls-flow.png` — accurate but for one detail

This is a corrected second revision. The first attempt named Keycloak as the
identity provider and used the wrong session-variable names; both are fixed.

Verified correct: the two authentication paths — applicants use email plus a
one-time code with an API-issued JWT, staff use **Azure External ID**
(`login.microsoftonline.com`) and only on the staff portal
(`foundational/sso.py:16`, `grantmakers/app/routes/sso.login.tsx:23`); tenant
resolution by `X-API-Key` then `X-Tenant-Domain`
(`backend/api/endpoints/auth.py:40-52`); the variables `rls.tenant` and
`rls.owner`, with owner correctly identified as the *organisation*; the four
access rules (`000000000000__rls.sql`); the read-only/read-write principal
split; and the F2 caveat, confirmed by execution — see `verification/`.

**The one error: `set_config(..., true)` should be `false`.** The diagram shows

```
set_config('rls.tenant', <tenant>, true)
set_config('rls.owner',  <owner>,  true)
```

The third argument is `is_local`: `true` scopes the setting to the current
transaction, `false` to the whole session. The code uses **`false`**
(`frontend/foundational/.server/db.ts:25-26`).

The backend does not use `set_config` at all — it issues plain
`SET rls.tenant = '...'` (`vendor/unrest/unrest/db/pool.py:67,69`), which is
also session-scoped, and restores the previous value when returning the
connection to the pool.

The distinction matters more than it looks. Session-scoped RLS context persists
on a **pooled** connection after the work finishes, so correctness depends on
every subsequent caller setting it again before querying. In the BFF that holds
— the `sql` wrapper sets both variables at the top of every transaction — and
the backend pool restores prior values on release. So this is not a defect, but
the diagram asserts a stronger guarantee (transaction-scoped, self-cleaning)
than the code provides. Worth drawing correctly precisely because the weaker
form is the one with a failure mode.

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
