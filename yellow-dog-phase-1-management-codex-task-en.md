# Codex Task A: Independent Management Application

Repository: `gsmlg-dev/yellow-dog`  
Target runtime: `yellow_dog_management`  
Phase: 1 — parallel refactoring, Management track

Implement working code, tests, configuration examples, and a runnable Management release. Do not stop at an implementation proposal.

Read the accompanying **YellowDog Phase 1: Parallel Management and Worker Refactoring** specification (`yellow-dog-phase-1-parallel-refactor-plan-en.md`) and the shared ConfigSpec baseline. Its Phase 1 decisions supersede earlier plans that required live Agent integration or prohibited PostgreSQL/schema migrations.

## Mission

Management must run independently with PostgreSQL and provide actual UI/API for DNS business data, logical Workers, service desired state, explicit resource assignments, immutable confirmed versions, complete target previews, and TOML export.

All of this must work with zero connected Workers. Business data must also be creatable with zero Worker records.

A parallel agent owns Worker execution. Do not implement or depend on a running Worker, enrollment, a management channel, heartbeats, remote configuration delivery, or remote acknowledgements.

## 1. Inspect the actual baseline

- Read applicable AGENTS.md files, repository build instructions, pinned development environment, current application boundaries, and shared contracts.
- Record actual HEAD and git status. Preserve unrelated and uncommitted changes. Do not reset to a historical review SHA.
- Run relevant existing checks using the documented pinned toolchain. Separate pre-existing failures from newly introduced failures.
- No old business-data migration, legacy-format compatibility, dual-write transition, or combined-runtime compatibility is required.
- Add normal Ecto database schema migrations for the new PostgreSQL model.
- Respect the shared-file owner. If the common baseline is missing, provide a minimal contract/build patch as a handoff and continue independent domain work. Do not invent a second validator or incompatible TOML format.

## 2. Establish the Management boundary

Provide one Management business entry point with its Web and domain layers. Its runtime dependencies may include required Web/database libraries and pure shared schemas, but not Worker or service execution implementations.

Management must not start DNS/DHCP listeners or an Agent, even indirectly. Inspect transitive release dependencies, not just feature flags.

UI/API call Management contexts. They must not call remote runtime modules, perform local DNS activation, or require a selected Worker to be online before saving data.

## 3. Implement Ecto/PostgreSQL domain persistence

Create or consolidate contexts and schemas for:

- Logical Workers: stable ID, name, expected capabilities, and not-yet-connected status.
- Worker service instances: service type, typed configuration, and desired running/stopped state.
- DNS Zones/RRsets: editable primary data and draft revision.
- Immutable resource versions: confirmed content and semantic digest.
- Explicit assignments from a resource version to Worker service instances.
- Confirmed complete WorkerPlans and revisions.
- Audit records and durable API idempotency outcomes.

Required semantics:

- A Worker record can be pre-created without an address, connection, or registration handshake. A logical ID is not authenticated physical-node identity.
- DNS data can exist unassigned. Do not require targets when creating a Zone.
- One Zone version can be assigned to four logical Workers without creating four independently editable Zone copies.
- Models support collections, not a hardcoded one-Worker or four-Worker limit.
- Use relational associations, foreign keys, uniqueness constraints, and explicit concurrency control. Typed JSONB is acceptable for immutable payloads, not as one giant replacement for the entire domain model.
- PostgreSQL is the only primary write path. Do not continue writing legacy Store/JSON state.
- Protect draft edits with expected revisions. Serialize concurrent updates to a Worker's aggregate target using suitable transaction/locking or compare-and-swap semantics.
- Confirming or changing Zone A must not overwrite Zone B's assignment or the DNS service's stopped state.
- Make resource versions, target changes, audit events, and idempotency outcomes transactionally consistent. Failed transactions leave no partially prepared target.
- Persist idempotency results so a request retried after application restart returns its original result rather than creating another version.
- Define deletion/unassignment without dangling references or silently rewriting retained historical targets.

Keep validation and target construction functional and testable. Keep database I/O inside contexts, not inside LiveView event handlers or format encoders.

## 4. Deliver actual UI/API workflows

Implement:

- Worker list, create, and edit.
- DNS Zone/RRset create, edit, delete, and immutable version confirmation.
- DNS service configuration and desired running/stopped state per Worker.
- Resource assignment/unassignment, including multi-Worker assignment.
- Complete target preview, previous-target diff, and selected-version TOML export.

Include authentication, authorization appropriate to the operator model, bounded inputs, structured errors, revision conflicts, and idempotent mutation handling.

Do not fabricate execution state:

- A stop action records desired stopped state; it does not mean an actual Worker has stopped DNS.
- An unconnected Worker has unknown actual state.
- A confirmed target is prepared, not applied or verified.
- Do not use mock remote success to make UI indicators appear complete.

The minimum DNS fixture is a complete authoritative SOA/NS/A zone. State the supported configuration surface accurately and reject unsupported input explicitly. Do not expand unrelated protocol features as a prerequisite for this task.

## 5. Implement ConfigCompiler and deterministic TOML export

Read a consistent confirmed database target, build the complete shared WorkerPlan, and encode it using the shared ConfigSpec.

- Reference explicit immutable resource versions, not a mutable latest pointer.
- Include exactly the target's assigned resources and preserve service desired state.
- Reflect unassignment as removal from the next complete target without changing unrelated bindings.
- Export managed service configuration and data, not machine-local identity, data-directory overrides, or management credentials. A plan may identify its intended Worker but must not rewrite its bootstrap identity.
- Separate database commit from file generation. Export is retryable for the same confirmed target revision and contains no Worker network calls.
- Validate the round trip: confirmed PostgreSQL data -> WorkerPlan -> TOML -> parsed normalized content -> equal semantic digests.
- Digest semantics follow ConfigSpec. Do not compare database rows directly to raw TOML bytes or implement independent canonicalization.

Only database/export consistency can be verified in Phase 1. Do not claim a physical Worker's files or runtime are consistent without observations.

Leave live adapters, Outbox dispatch, delivery retry, and runtime reconciliation to Phase 2. Do not build placeholder remote loops.

## 6. Parallel-work ownership

Own Management modules, database migrations, contexts, UI/API, ConfigCompiler, and related tests.

Do not edit the other agent's Worker runtime, LocalStore, or service execution code. ConfigSpec, shared fixtures, root mix.exs/mix.lock, shared config, devenv, release wiring, and top-level CI belong to the shared-file owner.

Prepare required shared-file changes as a named patch/handoff unless explicitly assigned ownership. Do not delete legacy modules still needed by the other branch. Coordinated integration will remove obsolete mixed entry points.

Do not introduce another business runtime, broker, generic scheduler, or a second source of truth.

## 7. Required acceptance tests

1. Start Management against a fresh migrated PostgreSQL schema with no Worker process or integration adapter.
2. Create and edit valid DNS data before creating any Worker record.
3. Create four logical unconnected Workers and assign one immutable Zone version to their DNS service instances.
4. Verify each target contains exactly its assigned data; unassigned data is excluded.
5. Create multiple zones; change/unassign one and verify the others and stopped state are preserved.
6. Test concurrent edits/assignments, transaction rollback, and explicit conflict results.
7. Restart Management and verify data, assignments, confirmed versions, plans, and idempotency outcomes remain correct.
8. Round-trip exported TOML through shared fixtures and normalization/digest validation; reject invalid, unsupported, and oversized input.
9. Verify Management's release dependency set and listeners exclude Worker/service execution and Agent components.
10. Exercise UI/API workflows without fake applied/verified observations.

Use fixed ConfigSpec fixtures independently of the Worker track. File-only interoperability is a later integration check: stop Management and PostgreSQL, then let Worker boot from an exported package. Do not block your domain implementation waiting for a live Worker.

## 8. Completion report and safeguards

Report:

- Actual baseline SHA and relevant existing failures.
- Changed files grouped by responsibility.
- Schema/context model, transaction boundaries, and concurrency/idempotency decisions.
- UI/API usage and TOML export examples.
- Exact commands executed and actual results.
- Checks not executed and concrete blockers.
- Shared-file patches awaiting integration and Phase 2 attachment points.

Do not claim release acceptance while its required shared wiring is still unintegrated or untested. Do not fabricate passing tests. Do not push, open PRs/issues, deploy production, or change real DNS delegations without separate authorization.
