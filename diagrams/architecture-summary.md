<!-- reviewed at commit 58fbc761 on 2026-10-06 -->
# Architecture summary (external analysis)

Text of the original `.docx`, extracted for diffability and in-browser
reading. The `.docx` itself is not kept: 4 MB of it was the three diagrams
re-embedded, and those are alongside this file as PNGs.

**Provenance:** produced by ChatGPT from `00-index.md`, `01-architecture.md`
and `02-data-model.md` — it did not read the codebase. Its "main gap: a
concise review-level summary is missing" was written before
`reviews/2026-10-06-investengland.md` existed, and is now addressed.

---

Based on repository documentation reviewed at commit 58fbc761
This document summarises the review of 00-index.md, 01-architecture.md and 02-data-model.md, together with the architecture views derived from that evidence.

## 1. Overall assessment

Strong
Evidence-driven, reproducible documentation. Claims are explicitly separated into verified and assumed findings.
Useful
The documentation identifies consequential architectural seams rather than merely listing components.
Weakness
Important review findings can be buried in long narrative sections and are not consistently prioritised by severity.
Main gap
A concise review-level summary is missing: top findings, impact, priority, recommended action, owner/status.

## 2. What is good

Claims are pinned to a specific commit and distinguish [verified] from [assumed].
Architecture and data-model concerns are separated cleanly, with planned follow-on documents for APIs, dependencies, deployment and testing.
The BFF seam is explained as a design decision: mutations go through the API while reads may query Postgres directly using a read-only credential.
The review surfaces structural issues that matter in practice: circular dependencies, RLS coverage gaps, missing primary keys/indexes, migration inconsistencies and view/RLS behaviour.
Where code cannot establish intent, the documentation turns the uncertainty into an explicit question for maintainers rather than inventing rationale.

## 3. What could improve

Separate 'how the system works' from 'review findings / risks'. At present these are interwoven.
Add severity and priority. A one-line import issue and a possible tenant-isolation issue should not read with the same visual weight.
Reduce duplicate treatment of tenancy/RLS and database principals across architecture and data-model documents.
Move detailed counts and forensic evidence into appendices or linked evidence notes where possible.
Use diagrams more aggressively for the BFF read/write split, tenant/RLS flow, integration resolution and database inheritance.

## 4. Architecture characterisation

The backend is best described as a layered/onion-style architecture with some strong hexagonal characteristics, especially around integrations. It is not a clean textbook implementation of either pattern.
Backend dependency direction: api/endpoints -> foundational -> unrest -> Postgres/Redis.
foundational contains most of the domain logic.
The integrations seam is strongly port-and-adapter-like: domain-facing service interfaces resolve to provider implementations at runtime.
The direct BFF-to-Postgres read path weakens a strict hexagonal interpretation because the database schema itself becomes a frontend-facing interface.

## 5. Key architectural findings

BFF seam: Reads may bypass the API and query Postgres directly; mutations are forced through the API.
Tenancy: Tenant isolation is primarily enforced in Postgres using tenant_id + owner_id and session RLS context.
Integrations: Provider selection is runtime and tenant-specific; domain code does not directly depend on vendor SDKs.
Async: Taskiq over Redis carries request context into workers; broker and scheduler use the same image with different commands.
Domain coupling: foundational contains several cross-area cycles, with entities acting as the main dependency hub.
Database inheritance: owned/entity inheritance gives consistent columns, but PKs, indexes, constraints and RLS do not propagate to child tables.
Critical review item: Views owned by admin may bypass underlying RLS unless security_invoker or FORCE ROW LEVEL SECURITY is used.
Integrity: Referential integrity is mostly application-enforced; the schema declares only one foreign key.

## 6. Architecture views

The following diagrams are conceptual views derived from the documented code and schema. They are intended for review, onboarding and stakeholder walkthroughs rather than as authoritative deployment IaC.
Request / data flow
Request / data flow
Tenant / auth / RLS flow
Tenant / auth / RLS flow
Conceptual ER model
Conceptual ER model

## 7. Conceptual ER interpretation

A literal foreign-key-derived ER diagram would be misleading because the database has only one declared foreign key. The useful view is therefore a conceptual model reconstructed from table names, inheritance and application usage.
Core domain shape: Tenant -> Organisation -> Application -> Project -> Payments
Programme and Fund provide funding context around the core grant domain.
Formal data, audit/history, locations and the ledger act as supporting or cross-cutting data stores.
Most lines in the conceptual ER represent logical/application relationships, not PostgreSQL foreign-key constraints.
Exact cardinalities cannot be asserted from the current documentation alone and should remain conceptual until validated against the code paths or maintainers.

## 8. Recommended next documentation step

Add a short REVIEW.md above the detailed documentation. It should contain the top 5-10 findings, severity, consequence, evidence link, recommended action and owner/status. The detailed architecture and data-model documents can then remain the evidence base rather than carrying the prioritisation burden.

## Source material

00-index.md - documentation index and review status
01-architecture.md - runtime topology, layering, BFF seam, tenancy, integrations, async work and structural boundaries
02-data-model.md - schema inventory, inheritance, RLS reach, views, integrity, formal store, ledger and migrations
