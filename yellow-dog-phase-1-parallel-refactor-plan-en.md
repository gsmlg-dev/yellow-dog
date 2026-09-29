# YellowDog Phase 1: Parallel Management and Worker Refactoring

Date: 2026-09-29  
Repository: `gsmlg-dev/yellow-dog`  
Status: Implementation specification. This document does not claim that the work has been completed or that the current repository has been verified against it.

## 1. Objective and controlling decisions

Deliver two independently deployable business applications:

- **`yellow_dog_management`**: Ecto + PostgreSQL, management UI/API, business data ownership, logical Worker definitions, service configuration, explicit resource assignments, and deterministic TOML export.
- **`yellow_dog_worker`**: standalone service hosting driven exclusively by local TOML configuration and resource files, with local reload, status inspection, and reliable recovery.

Phase 1 has two parallel implementation tracks. Neither track depends on a running counterpart. Network integration is Phase 2 work, not a Phase 1 acceptance condition.

The following decisions supersede earlier implementation plans where they conflict:

1. There are exactly two supported business runtime entry points: Management and Worker. Shared libraries and Worker-hosted service libraries are not additional deployment roles.
2. Management owns editable business data in PostgreSQL. Worker does not connect to PostgreSQL.
3. Worker must function with no Management address, credentials, registration, connection, or reachable Management server.
4. Do not implement enrollment, a management WebSocket client, heartbeats, remote delivery, delivery acknowledgements, or connected reconciliation in Phase 1.
5. Do not migrate old business data, preserve legacy persistence formats, introduce dual writes, or maintain a combined Management/Worker runtime. Ecto database schema migrations are still required.
6. Use real authoritative DNS as the first end-to-end service implementation. A complete valid SOA/NS/A zone is the minimum fixture. Explicitly document and reject unsupported configuration rather than silently discarding it.
7. Do not make unrelated protocol expansion, DHCP, NetBoot, Netman, DNSSEC, or a full DNS feature rewrite prerequisites for this architectural phase.
8. This is an implementation task: deliver code, tests, configuration examples, and runnable application entry points, not only an architecture proposal.

## 2. Future behavior that Phase 1 must not prevent

Do not implement the network mechanism yet, but preserve these ownership rules:

- Management's published desired state will be authoritative for the managed service scope.
- Worker reports will describe local state; they will not automatically merge local edits back into PostgreSQL.
- After authenticated reconnection, Management's complete desired state will replace local differences, including explicit resource removals and stopped services.
- No response, an incomplete response, an uninitialized target, and a timeout are not an explicitly empty desired set.
- Loss of the management connection must never automatically stop business services.
- After disconnection, Worker continues using its last successfully committed local configuration and data.
- Updating the configuration or data of a stopped service must not start it. A committed stopped state must survive Worker restart.
- Future remote configuration and current local files must converge on the same validated WorkerPlan and the same execution path. Do not create a separate remote DNS installer later.

## 3. Minimal shared baseline: C0

C0 is a small shared-contract preparation step, not a third long-running product workstream.

Designate one owner for shared files. Establish the contract, fixed fixtures, and release/dependency skeleton, then branch both tracks from that baseline. The two agents must not independently invent incompatible formats.

### 3.1 Shared ConfigSpec library

Use one pure, runtime-free configuration specification library. Follow repository naming conventions for its final package and module names.

Responsibilities:

- Typed configuration and resource structures.
- Schema-version checks and structured validation errors.
- Domain-specific normalization, semantic digests, and pure diff calculation.
- TOML encoding/decoding, or one explicitly pinned shared codec adapter.

The shared library must not start processes, read deployment environment variables, connect to a database, open listeners, or execute service operations. It must not depend on Management, Worker, Phoenix, an Ecto Repo, or service runtime implementations. Pin and test the supported TOML syntax version.

### 3.2 Contract concepts

| Concept | Required meaning |
|---|---|
| Worker identity | A bounded, stable, explicitly configurable ID. Its existence does not depend on an active connection. |
| Service instance | Instance ID, allowlisted service type, desired `running`/`stopped` state, typed configuration, and resource references. |
| Resource | Stable ID, resource type, schema version, immutable version, normalized content, and content digest. |
| WorkerPlan | The complete intended service/resource set for one Worker, not the most recently issued command. |
| Plan revision | Separate from draft revision, resource version, and DNS SOA serial. |
| Diff | Structured additions, replacements, removals, and lifecycle changes, with no execution side effects. |
| Observation | Actual runtime state, readiness, loaded content identity, and errors; distinct from desired state. |

A pre-created Worker record is a logical allocation target, not proof that a physical Worker has authenticated. Trusted binding belongs to Phase 2.

### 3.3 Resource assignment semantics

- Business data can be created before any Worker exists and can remain unassigned.
- One logical Zone and its selected immutable version can be assigned to several Workers' DNS service instances. Do not create separately editable copies per Worker.
- A Worker can receive several zones. Updating or assigning one must not remove another.
- Drafts and confirmed versions are distinct. Export references explicit immutable versions, not a mutable `latest` pointer.
- Unassignment removes the resource from the next complete target without deleting unrelated assignments or other Workers' bindings.
- Explicit Worker selection is sufficient. Groups, scheduling, geography, and placement optimization are out of scope.
- Collection-shaped models must not hardcode a one-Worker or four-Worker limit. Four logical Workers are an acceptance fixture.

### 3.4 TOML and digest semantics

- Human-authored source files need not contain manually calculated digests. The loader validates and computes them.
- Generated packages that include expected digests must be checked against their actual parsed content. Never trust a declared digest without recomputing it.
- Semantic digests describe normalized business meaning, not TOML formatting, comments, or key order.
- Normalize and sort only collections whose ordering has no meaning. Preserve meaningful ordering and case-sensitive record content.
- Exclude observations, local file placement, and machine-specific bootstrap settings from shared DNS content digests. Keep typed service settings in their appropriate service/plan digest.
- Separate machine-local bootstrap configuration from managed service configuration. Export must not overwrite local identity, data-directory settings, or future management credentials. A target ID in a plan is checked for compatibility; it does not rewrite local identity.
- Both hand-authored configuration and Management exports normalize to the same WorkerPlan.
- Define missing fields, defaults, explicit empty sets, and removals precisely. Parsing failure is never a deletion instruction.

### 3.5 Shared fixtures

Provide fixed fixtures for:

- A valid authoritative DNS SOA/NS/A zone.
- Multiple zones and independent assignments.
- Running and stopped services.
- An explicitly empty resource set.
- Missing references and duplicate resources/instances.
- Malformed TOML, unsupported data, and configured input limits.
- Incorrect expected digests.
- Semantically equivalent TOML with different formatting.

Each track tests against these fixtures independently of the other track's application.

## 4. Track A: Independent Management

### 4.1 Runtime boundary

With only Management and PostgreSQL running, an operator must be able to use UI/API to create DNS data, define logical Workers, configure service targets, assign resources, preview desired configurations, confirm versions, and export TOML packages.

Worker connectivity is an optional future adapter. No domain write or configuration export may require a Worker address, connection, or live response.

### 4.2 Domain and persistence

Use Ecto contexts and PostgreSQL for:

- Logical Workers: identity, name, operator-declared expected capabilities, and not-yet-connected status.
- Service instances: Worker association, service type, desired state, and configuration.
- DNS Zones/RRsets: primary business data, draft revision, and complete-zone validation.
- Immutable resource versions and digests.
- Explicit resource assignments.
- Confirmed complete WorkerPlans and their revisions.
- Audit records and durable API idempotency outcomes.

Use suitable relational structure, foreign keys, uniqueness constraints, and concurrency controls. A schema-validated JSONB payload is acceptable for immutable resource content; one global GenServer map or one giant JSONB document is not a substitute for the domain model.

The new write path uses PostgreSQL only. Do not dual-write legacy Store/JSON persistence. Protect edits with revision checks and protect concurrent target changes with transactions and suitable locking or compare-and-swap checks.

Resource versions, assignment changes, confirmed target plans, audit records, and related idempotency outcomes must have explicit transactional boundaries. A failed transaction must not leave a partially confirmed target. Concurrent changes to different zones assigned to one Worker must not lose either zone.

### 4.3 UI/API

Implement actual usable operations for:

- Listing, creating, and editing logical Workers.
- Creating, editing, deleting DNS data, and confirming valid immutable versions.
- Defining DNS service instances and desired running/stopped state.
- Assigning/unassigning resources, including one resource assigned to several Workers.
- Previewing complete targets and differences from the previous confirmed target.
- Exporting a selected confirmed TOML package.

Controllers and LiveViews use Management contexts, not Worker or DNS execution modules. Include authentication, authorization appropriate to the stated operator model, bounded inputs, structured errors, concurrency conflict handling, and idempotent mutation behavior.

A stop operation in this phase records desired state only. Display actual state as unknown until real observations exist. A confirmed configuration is `prepared` or an equivalent accurate state; do not fabricate `online`, `applied`, or `verified` results.

Define deletion and unassignment consistently so retained immutable targets remain interpretable and newer targets explicitly omit removed resources.

### 4.4 ConfigCompiler and export consistency

ConfigCompiler builds a complete normalized WorkerPlan from a consistent confirmed database snapshot. ConfigSpec serializes that plan and its referenced content into TOML.

Export only immutable selected versions. Generate files after the database transaction from its committed snapshot; do not perform remote calls inside the transaction. A failed export is retryable for the same target revision.

Verify:

**Confirmed PostgreSQL snapshot -> WorkerPlan -> TOML -> parse again -> equal normalized content and semantic digests.**

This proves database/export consistency only. It does not prove the state of a physical Worker's disk or runtime.

Live adapters, delivery workers, Outbox dispatch, retry scheduling, heartbeats, and remote observation reconciliation are Phase 2 work. Do not implement empty versions of them merely to make the architecture appear connected.

### 4.5 Acceptance criteria

- **A1:** Management starts against a newly initialized PostgreSQL schema and exposes UI/API.
- **A2:** DNS data can be created and edited with zero Worker records and zero Worker processes.
- **A3:** Four logical, unconnected Workers can be created and assigned the same Zone version.
- **A4:** Each target contains exactly its assigned resources; unassigned data is not exported to it.
- **A5:** Changing/unassigning one zone preserves other zones and a service's stopped state.
- **A6:** Concurrency conflicts and transactional failures do not create partial or lost target changes.
- **A7:** Idempotent retries after application restart recover the same mutation result.
- **A8:** Data, assignments, immutable versions, and targets survive application restart.
- **A9:** Export round-trip validation, digests, bounds, and shared fixtures pass.
- **A10:** The Management release does not include Worker/service execution dependencies or start DNS, DHCP, or an Agent.
- **A11:** All operations work without an integration adapter, and UI/API report no fabricated runtime success.

## 5. Track B: Standalone TOML-driven Worker

### 5.1 Runtime boundary

Worker starts from local configuration and resource files without PostgreSQL, a Management URL, registration, credentials, or a management connection.

Internal responsibilities:

- ConfigLoader: bounded source-file reads and safe resource-reference resolution.
- ConfigSpec: pure validation, normalization, digests, and diffs.
- LocalStore: immutable TOML snapshots, commit/recovery records, and last-valid state.
- ServiceManager: the single local service-management entry point.
- Per-service ServiceController: serialized lifecycle/configuration/resource execution and recovery.
- Service adapters: explicitly registered implementations; authoritative DNS is the first real adapter.
- Local status: process state, service readiness, loaded versions, and errors.

Resolve service types through a compile-time allowlist. Do not convert arbitrary TOML strings to atoms or executable modules. Inject runtime configuration and local dependencies explicitly; service implementations must not depend on Management, an Ecto Repo, or the host application's global entry point.

### 5.2 Configuration and recovery semantics

Keep human-editable source files, machine-local bootstrap configuration, and committed snapshots separate.

The documented Phase 1 mutation mechanism is editing local files and invoking an explicit reload. Define one unambiguous startup/reload precedence policy and test it; do not let multiple implicit sources race.

- Valid first-boot configuration starts the declared services.
- Invalid first-boot input with no last-valid snapshot fails explicitly or remains not ready, without demo data.
- Reload validates the complete candidate, computes a diff, then uses ServiceController to apply it.
- A successful reload commits the new local state for restart recovery.
- Invalid source or failed application preserves last-valid state and exposes the error. Recovery on the previous version must be clearly reported, not described as successful loading of the rejected candidate.
- A semantically identical reload does not rewrite healthy committed snapshots or restart healthy services.
- A committed stopped state survives restart.
- Updating data for a stopped service may prepare and persist the data, but cannot implicitly start it. A later explicit start loads the specified valid version.
- Any optional local start/stop command must update the same persistent desired-state path. Do not introduce hidden memory-only overrides.
- Do not require network connectivity for readiness or secretly probe Management during boot.

### 5.3 LocalStore and runtime safety

Use one clearly owned local storage path. Refuse a second Worker instance attempting to use the same data directory.

Restrict resource paths to allowed roots; reject path traversal and disallowed symlink escapes. Bound file size, resource count, and parsing complexity. Validate any declared content identity against actual file contents.

Stage candidates without clearing active data. Read generated TOML back and validate it. Commit records must atomically reference complete, already-persisted immutable file sets. Sequentially overwriting several active files is not a transaction.

Specify and test file synchronization, directory synchronization, commit-pointer replacement, previous-version retention, and recovery from interruption. Handle permission failures, disk-full/write failures, post-rename failure, and process termination. Do not call an untested rename-only sequence power-loss safe.

Garbage collection must retain active, previous-valid, and in-progress resources. Record actual per-service outcomes if a multi-service plan partially applies; cross-service simultaneous cutover is not required.

DNS queries use loaded memory, not per-query TOML reads. Distinguish Worker liveness, service process existence, listener readiness, and actual loaded content.

The consistency checker produces structured differences. All repair goes through ServiceController; do not introduce a second file writer or direct restart path.

### 5.4 Acceptance criteria

- **B1:** Worker boots with Management/PG settings unset and management connectivity unavailable.
- **B2:** TOML starts authoritative DNS with valid SOA/NS/A data, verified using actual UDP and TCP queries.
- **B3:** Disabled services have no listeners. Worker remains available for local control/status when all services are stopped.
- **B4:** Editing A data and explicitly reloading switches to complete new answers without a partial RRset.
- **B5:** Stopping DNS closes its listeners but not Worker; restart preserves stopped state.
- **B6:** Updating data while stopped does not start DNS; a later start uses the new selected content.
- **B7:** Restart without Management restores the committed local configuration and data.
- **B8:** Invalid formats, unsupported modules/data, duplicate instances, missing resources, path escapes, and excess inputs fail explicitly.
- **B9:** Validation/write/application failure and process interruption preserve a complete recoverable version with no false success.
- **B10:** Identical healthy reloads perform no snapshot writes or service restarts; missing runtime projections can still be repaired through the same entry point.
- **B11:** The Worker release does not depend on Management, Repo/Postgrex, management UI, or a hidden database service.
- **B12:** LocalStore/runtime inconsistency is observable with clear desired, prepared, persisted, and active state where applicable.

## 6. Parallel ownership and integration

| Files/responsibility | Owner |
|---|---|
| Management application, Ecto, contexts, UI/API, ConfigCompiler, tests | Track A |
| Worker application, LocalStore, ServiceController, DNS adapter, tests | Track B |
| ConfigSpec, shared fixtures, root `mix.exs`/`mix.lock`, shared configuration, release/devenv setup, top-level CI | Shared-file owner |

Suggested branches: `refactor/phase1-management` and `refactor/phase1-worker`, using separate worktrees from the same C0 baseline.

Route shared-file changes through their owner. If running alone without an available owner, prepare a minimal shared-contract/build patch and document the handoff; continue independent work without creating a competing format. Do not silently modify shared files from both tracks.

Do not delete legacy modules still used by the other in-progress branch. Remove obsolete mixed entry points during coordinated integration. This temporary source coexistence is not a requirement to support legacy persistence or runtime behavior.

Acceptance still requires integrated runnable releases. A pending shared build patch is a remaining integration dependency, not permission to claim an unbuilt release passes.

## 7. File-only compatibility check

First pass each track's acceptance tests independently against fixed fixtures. At integration time:

1. Create DNS data in Management and configure a logical Worker's service and assignment.
2. Confirm and export its TOML package.
3. Stop Management and PostgreSQL.
4. Provide the exported package to Worker as local input, with compatible machine-local bootstrap parameters.
5. Start Worker and verify the exported DNS content using actual UDP/TCP queries.
6. Restart Worker and verify the same committed content.

This proves offline configuration compatibility, not remote enrollment, delivery, or four-node connected convergence.

## 8. Explicit exclusions and completion reporting

Do not implement legacy business-data migration, dual writes, Worker-to-PG access, a live Agent, enrollment, heartbeats, remote acknowledgements, complex scheduling, Management HA, new brokers, unrelated protocol expansion, four-node network failure drills, or production changes.

Each task reports actual baseline SHA, changed responsibilities/files, interfaces, precise executed commands and results, unexecuted checks and concrete reasons, shared-file handoffs, and remaining Phase 2 integration points.

Do not fabricate test results. Do not push, open PRs/issues, deploy production, or change real DNS delegations without separate authorization.

Phase 1 is complete when both independent applications and file-only interoperability pass. Phase 2 then adds authenticated attachment, remote target delivery, observation reports, durable retry, and online reconciliation without changing data ownership or creating a parallel execution path.
