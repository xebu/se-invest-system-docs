<!-- reviewed at commit 58fbc761 on 2026-10-06 -->
# InvestEngland — interfaces

Scope: the HTTP surfaces (API, integrations service, webhooks), how callers are
authenticated and authorised at the edge, the serialisation and error contracts,
and the BFF↔API agreement. Claims are `[verified]` or `[assumed]`.

## What matters here

1. **Six permissions are seeded into the permissions matrix but enforce
   nothing** — four of them granted to roles by migration 109 (§3.1).
2. **The Credas webhook is unauthenticated and says so in a TODO**, while the
   Stripe one verifies its signature properly (§8).
3. **The public webhook routes point at an API route that does not exist** —
   either dead code or a broken identity-verification callback path (§8.1).

Everything else is in good order: the surface is consistent, the error model is
documented and matches the code, and the transport layer is thin.

---

## 1. Surface inventory

**API service** — 164 endpoints across 18 modules [verified by parsing every
`@api.query` / `@api.mutate` decorator in `backend/api/endpoints/`]:

| | Count |
|---|---|
| `@api.mutate` (POST) | 123 |
| `@api.query` (GET/QUERY) | 41 |

| Module | Endpoints | Module | Endpoints |
|---|---|---|---|
| `organisations` | 23 | `membership` | 9 |
| `workspaces` | 23 | `auth` | 8 |
| `applications` | 21 | `__init__` | 6 |
| `finance` | 18 | `administration` | 6 |
| `projects` | 17 | `demo` | 5 |
| `payments` | 11 | `compliance`, `formal` | 4 each |
| | | `contacts`, `files`, `geo`, `tenants` | 2 each |
| | | `programmes` | 1 |

**Integrations service** — 19 endpoints (`backend/integrations/integrations.py`)
[verified].

**No API versioning of any kind.** Paths are unprefixed (`/application`,
`/organisation/{id}`, …); there is no `/v1`, no version header, and no
deprecation mechanism [verified]. Tolerable while the only consumers are the two
first-party BFFs deployed from the same commit, but it means the API cannot be
evolved independently of them — worth a decision before any third party or
mobile client is admitted.

## 2. Authentication

One authentication hook on each service, registered via `@api.authentication`.

**API** (`api/endpoints/auth.py:36-52`) resolves the tenant first, then the user:

```
   X-API-Key present? ──yes──▶ tenants.get_by_api_key(key)
            │
            no
            ▼
   X-Tenant-Domain present? ──yes──▶ tenants.get_by_domain(domain)
            │                         (in development: domain is replaced with
            no                         a hardcoded value — auth.py:46-47)
            ▼
   UnauthenticatedUser + empty Tenant
            │
            ▼
   then: Authorization: Bearer <jwt> ──▶ authn.authenticate_jwt_token(token, tenant)
```

Each tenant has its own JWT secret, so a token cannot cross tenants; the handler
still checks `user.tenant == tenant.identity` and logs a
`PERMISSION_DENIED` security event on mismatch, with a comment noting it "can't
happen … but for clarity" [verified]. That is the right instinct.

The `X-Tenant-Domain` path is a documented concession — the handler's own
comment explains the API cannot rely on its own hostname to identify the tenant,
because it does not run on an organisational domain. The BFF forwards the
browser's hostname in that header (`.server/context.ts:35`) [verified].

**Integrations service** (`integrations/integrations.py:24-45`) accepts only a
bearer token matched against `tenants.get_by_api_key`, and logs malformed
headers as `LOGIN_FAILURE` security events [verified]. It has no JWT path — it
is a service-to-service surface.

## 3. Authorisation at the edge

Permissions are decorator arguments, so the guard is visible on every route.
Distribution across the 164 endpoints [verified]:

| Guard | Endpoints |
|---|---|
| `Roles.staff` | 42 |
| `Roles.user` (customer ∪ staff) | 37 |
| `Roles.customer` | 23 |
| `auth.Unrestricted` | 16 |
| `Roles.administrator` | 6 |
| 21 fine-grained permissions | 1–4 each (40 total) |

So roughly two-thirds of the surface is guarded by a coarse role and a third by
something specific. For a system where the fine-grained permissions carry the
real money semantics (`can_authorise_payments`, `can_approve_applications`),
that split is reasonable — reads are coarse, state transitions are specific.

### 3.1 Six permissions enforce nothing

`Roles` declares 29 distinct permission names. **23 are referenced somewhere in
backend code; 6 are not referenced anywhere** [verified by cross-referencing
every `Roles.<name>` in `api/endpoints/` and `foundational/`]:

`can_create_funds`, `can_manage_funds`, `can_create_programmes`,
`can_manage_programmes`, `can_override_project_finance`,
`can_update_sensitive_organisation_data`.

They are not merely unused constants. **Four of them are seeded into the
permissions matrix** by `migrations/000000000109__permissions_matrix_v0_2.sql`
— `can_create_programmes`, `can_manage_programmes`,
`can_override_project_finance`, `can_update_sensitive_organisation_data`
[verified] — and all six appear in the frontend's permission matrix
(`frontend/foundational/roles_and_permissions.ts`), where each appears exactly
once: in the matrix definition itself, never in an assertion [verified].

So an administrator can grant a role `can_manage_programmes`, the grant is
stored and displayed, and it confers nothing. Conversely, the operations those
permissions name are either guarded by something coarser or not exposed at all.

There is a benign reading, and it is probably the right one: **programmes and
funds have no creation endpoints at all**. `create_programme` exists in the
domain layer (`foundational/entities/programmes/__init__.py:45`) but no route
calls it; programmes and funds are seeded from
`backend/tenants/sportengland/static/{programmes,funds}.json` at tenant
initialisation [verified]. The permissions anticipate a back-office capability
that has not been built yet. `can_override_project_finance` and
`can_update_sensitive_organisation_data` are harder to explain that way, since
projects and organisations *are* mutable through the API.

Either way the matrix over-promises, which is a correctness problem for anyone
reasoning about least privilege from the matrix rather than from the code.
**Question for the team:** are these forward-declarations, or did an enforcement
point get missed?

## 4. The unauthenticated surface

16 endpoints are `Unrestricted` [verified]. Categorised:

| Endpoint(s) | Assessment |
|---|---|
| `/healthcheck` | expected |
| `/login`, `/verify`, `/register/code`, `/register`, `/sso` | necessarily public — pre-authentication |
| `/organisation/identity/{person_id}/consent` | public by design — the IDV consent step, reached from an emailed link |
| `/openapi.json`, `/docs`, `/redoc` | gated on `is_production()` — see **F1** |
| 5 × `/.demo/*` | gated on `is_production()` — see **F1** |

The first seven are correct. The last eight are only "unauthenticated in
non-production" if `is_production()` works, which is finding **F1** — the
review's top item. Note the shape of the risk: `/.demo/postcommit/{project_id}`
force-authorises payments and `/.demo/admin` mutates every tenant's funding
configuration under `systemcontext`, so these are not read-only conveniences.

The IDV consent endpoint deserves a note. It is genuinely public and takes only
a `person_id` (a UUID) as its path parameter, and the BFF reads
`idv_persons`/`idv_sessions` with the raw connection to render that page because
no tenant context exists yet (`frontend/foundational/authn.ts:66-78`)
[verified]. Security therefore rests entirely on the unguessability of the UUID.
That is a common and defensible pattern for emailed links, but it is worth
stating plainly, and the surrounding tables are two of the un-RLS'd ones
(`02-data-model.md` §3) — which in this case is consistent, not accidental.

## 5. Serialisation and the error model

Request and response shapes are **inferred from type annotations**, not
declared separately. `unrest` reads the handler signature: a `Payload` subclass
parameter becomes the request body (Pydantic v2 under the hood), and the return
annotation becomes the response schema
(`vendor/unrest/unrest/api/payload.py`, `serialisation.py`) [verified]. Handlers
therefore read as plain functions:

```python
class CreateApplicationRequest(Payload):
    organisation_id: str
    programme_id: str

@api.mutate("/application", Roles.customer)
async def create_application(payload: CreateApplicationRequest):
    return await applications.create(payload.organisation_id, payload.programme_id)
```
(`api/endpoints/applications.py:9-23`)

Not every handler is typed this way — several take a bare `dict` (e.g.
`update_application_form(form: dict, application_id)`,
`applications.py:28-31`), which opts out of validation entirely for form
payloads. That is consistent with the `formal` design, where the form's own
schema does the validating, but it does mean the OpenAPI document is silent
about those bodies.

**Errors** are a six-type hierarchy mapped to HTTP status in middleware. This
was checked against the code rather than taken from the docs, and
`docs/ERRORS.md` is accurate — the mapping it tabulates matches
`vendor/unrest/unrest/routing.py:122-161` exactly [verified]:

| Exception | Status |
|---|---|
| `NotFoundError` | 404 |
| `InvalidStateError`, `ConcurrencyError` | 409 |
| `ClientError` | 400 |
| `AuthenticationError`, `Unauthorized` | 401 |
| `InsufficientPrivilegeError` (asyncpg), `ContextError` | 403 |
| `ServerError`, unhandled `Exception` | 500 |

Two details worth knowing. Full exception messages reach the client at 500 only
when `verbose_errors` is set [verified] — fail-safe by default. And asyncpg's
`InsufficientPrivilegeError` mapping to 403 means **an RLS or grant violation
surfaces as a clean Forbidden** rather than a 500, which is a thoughtful touch.

The BFF translates these back for the browser: `Module.errorResponse` extracts
`.message` from the JSON body and rethrows a `Response` with the original status
(`.server/modules.ts:71-77`) [verified], so status codes propagate to route
error boundaries rather than being flattened.

## 6. OpenAPI

There is no hand-maintained spec. `/openapi.json` is generated at request time
by walking the registered Starlette routes and reflecting each handler's
`payload` and `returns` types into JSON Schema
(`api/endpoints/__init__.py:74-192`) [verified]. `/docs` serves Swagger UI and
`/redoc` serves ReDoc, both from CDN script tags.

Generated-from-code is the right call — it cannot drift. Two observations:

- Handlers taking a bare `dict` contribute no request schema (§5), so the
  document is incomplete precisely where the dynamic-form payloads are.
- All three routes are gated on `is_production()` and are therefore implicated
  in **F1**. An exposed `/openapi.json` is not itself a vulnerability — it is a
  map, and the endpoints remain guarded — but it removes any obscurity around
  the 16 unauthenticated routes.

## 7. The integrations service interface

19 endpoints, organised by compliance/finance domain rather than by provider
[verified: `integrations/integrations.py`]:

| Group | Endpoints |
|---|---|
| Due diligence | `/duediligence/company/{n}`, `/duediligence/charity/{n}`, `/lookup/company/{n}`, `/lookup/charity/{n}` |
| AML | `/aml/company`, `/aml/individual`, `/aml/hit/decide` |
| Identity | `/identity`, `/identity/{organisation_id}` |
| Payments | `/payments/batch`, `/payments/reconcile`, `/bankdetails/check` |
| Ledger | `/ledger/export` |
| Geo | `/geo/address/postcode`, `/geo/meta/point`, `/geo/places/postcode` |
| Webhooks | `/webhooks/stripe`, `/webhooks/credas` |
| Health | `/healthcheck` |

The important property is that **this surface mirrors the abstract service
interfaces** declared in `foundational` — `AntiMoneyLaunderingService`,
`DueDiligenceService`, `IdentityVerificationService`, `BankDetailsService`,
`PaymentsService`, `LedgerService` and three geo services. That is what lets the
`$proxy` implementations satisfy the same Python interface over HTTP
(`01-architecture.md` §6). The HTTP surface is a transport for an interface that
exists in code, not an independently-designed API — which is why it has no
versioning problem of its own.

All 16 non-webhook, non-health endpoints use the default guard
(`auth.UserIsAuthenticated`), satisfied by the tenant API key [verified].

## 8. Webhooks

Two inbound provider callbacks, both necessarily `Unrestricted` at the route
level, so authentication has to happen inside the handler. One does, one does
not.

**Stripe — verified.** The route forwards the `Stripe-Signature` header into the
client (`integrations.py:166-174`), and the shared helper calls
`stripe.Webhook.construct_event` with `STRIPE_HOOK_SECRET`
(`foundational/infra/stripe.py:32`) [verified]. Correct.

**Credas — not verified.** `process_webhook(payload)` is handed the parsed body
and carries an explicit admission
(`integrations/implementations/kyc/credas.py:84`) [verified]:

```python
# TODO: validate webhook payload, e.g. check signature, check expected fields, etc.
```

It then reads `payload['ProcessId']` and `payload['Status']` from the untrusted
body. The exposure is narrower than it first appears: the handler immediately
calls back to Credas for the real process and entity summary
(`get_process`, `get_entity_summary`), so identity data cannot simply be
fabricated in the request. What an unauthenticated caller *can* do is drive
processing of an arbitrary or replayed `ProcessId`, and `payload['Status']`
is read directly — a mismatch only logs a warning and continues
(`credas.py:81-82`). Given this path completes **identity verification** for an
organisation's named people, it should authenticate.

**A logging bug in both handlers.** The success path logs
`SecurityEventType.WEBHOOK_REJECTED` with outcome `"success"`
(`integrations.py:174-178` and `:195-199`) [verified]. A successfully processed
webhook is recorded as *rejected*. Any dashboard or alert built on
`WEBHOOK_REJECTED` counts is inverted. Trivial to fix; worth fixing before
anyone builds monitoring on it.

### 8.1 The public webhook routes target a route that does not exist

`grantseekers` exposes two public routes,
`_public.webhooks.stripe.tsx` and `_public.webhooks.credas.tsx`, which call
`Authn.proxyWebhook(provider, payload, headers)`
(`frontend/foundational/authn.ts:62-64`). That posts to
`` `${ctx.host}/webhooks/${provider}` ``, and `ctx.host` is `config.backendHost`
= `BACKEND_HOST` (`.server/context.ts:17`) — the **API** service.

The API has no `/webhooks` route. An exhaustive search of `backend/api/` and
`backend/foundational/` finds none; the only `/webhooks/*` routes are on the
**integrations** service, and the BFF has no integrations host in its config at
all [verified].

So one of two things is true, and I cannot tell which from the clone:

- **(a)** The providers are configured to call the integrations service directly
  (plausible — it is the natural target, and the local gateway exposes
  `integrations.localhost`), and these two frontend routes are dead code.
- **(b)** The providers call the public frontend, and the proxy 404s —
  meaning Stripe and Credas identity callbacks never land.

Evidence leans towards (b) being a genuine break rather than (a) being tidy
dead code: the Stripe route carefully forwards the `Stripe-Signature` header,
which only matters if the call is expected to reach a verifying handler. Someone
built this to work.

**Recommended check:** the webhook URL registered in the Stripe and Credas
dashboards. If it points at `external.*`, this is broken in production. Logged
as finding **F20**.

## 9. The BFF↔API contract

There is no generated client and no shared schema. `Module` (36 lines of
`.server/modules.ts`) wraps `fetch` with four things: the backend host, the
`X-API-Key` and `X-Tenant-Domain` headers, the forwarded `Authorization` bearer,
and error translation [verified]. Each domain module then hand-writes paths:

```ts
async createApplication(organisation_id: string, programme_id: string) {
  return await this.post("/application", { organisation_id, programme_id });
}
```
(`frontend/foundational/applications.ts:22-24`)

Return types are asserted, not validated — `this.post<T>(...)` casts
(`modules.ts:88`) [verified]. So a backend response-shape change is a silent
runtime failure in the BFF rather than a type error, in exactly the same way
that a column rename is for the direct-SQL path (**F6**). The two halves of the
BFF have the same weakness for the same reason: no contract at the boundary.

`deform(FormData)` converts form posts into a JSON payload, skipping keys
beginning `_` and the `action` key (`modules.ts:95-104`) [verified] — the bridge
between Remix's form-data convention and the API's JSON.

One acknowledged violation: `Module.audit()` posts directly to `/audit`,
breaking the "all mutations through the API domain layer" intent. Both sides
carry a note saying it should go (**F17**).

## Open questions

1. §3.1 — are the six unenforced permissions forward-declarations for
   unbuilt back-office features, or missed enforcement points? Specifically
   `can_override_project_finance` and
   `can_update_sensitive_organisation_data`, where the underlying operations
   *are* exposed.
2. §8.1 — what webhook URL is registered with Stripe and Credas?
3. §8 — should the Credas webhook authenticate before acting, given it
   completes identity verification?
4. §1 — is the absence of API versioning a deliberate consequence of
   lock-step BFF deployment, and does that hold if a third-party consumer
   appears?
