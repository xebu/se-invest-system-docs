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
| `request-data-flow.png` | Read/write paths, async runtime, integrations, providers | **accurate** |
| `tenant-auth-rls-flow.png` | Tenant resolution, authorisation, RLS enforcement | **accurate** |
| `combined-request-and-tenant-security.png` | Both of the above, as a single two-panel view | **top panel accurate; bottom panel has errors — see below** |
| `architecture-summary.md` / `.docx` | Written analysis accompanying the diagrams | accurate as a summary of docs 00–02 |

---

## Accuracy check

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

### `tenant-auth-rls-flow.png` — accurate

Verified: tenant resolution by `X-API-Key` then `X-Tenant-Domain`
(`backend/api/endpoints/auth.py:40-52`); the session variables are correctly
named `rls.tenant` and `rls.owner`; the four access rules match
`backend/sql/migrations/000000000000__rls.sql`; and the read-only/read-write
principal split is real.

It also carries the right caveat: *"Views owned by admin may bypass underlying
RLS unless security_invoker or FORCE RLS is used."* That is finding **F2**,
which was confirmed by execution — see `verification/`.

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

**Recommendation:** regenerate the bottom panel with the three corrections, or
publish `tenant-auth-rls-flow.png` on its own — it covers the same ground
correctly.
