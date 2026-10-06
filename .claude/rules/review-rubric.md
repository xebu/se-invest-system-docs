# Review rubric: quality and architecture

Assess in this order:
1. Structure: module boundaries, layering, dependency direction, circular deps
2. Coupling and cohesion: where does a change ripple?
3. Data and state: schema ownership, migrations, shared mutable state
4. Error handling and observability: failure modes, logging, metrics
5. Testing: what is covered, what is mocked, what is untested but critical
6. Dependencies: age, maintenance status, licensing, pinned vs floating
7. Build and deploy: reproducibility, environments, config handling
8. Maintainability: dead code, duplication, naming, docs vs reality

Severity: High (blocks change or risks outage), Medium (slows change), Low (hygiene).
Report only what you verified in code. Anything inferred is labelled assumed.
Generic for now: tune to the real stack after the first survey.