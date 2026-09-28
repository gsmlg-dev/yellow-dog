# YellowDog Authoritative DNS v1 — Implementation Plan

Prepared: 2026-09-28  
Repository: `gsmlg-dev/yellow-dog`  
Review baseline: `8656195519bdf21f5f15035a04d520b2897e99e2`  
Status: Proposed implementation contract; no implementation or new repository verification performed for this document.

## 1. Product goal and delivery boundary

Deliver one cloud management runtime controlling four independently deployable authoritative DNS servers. Operators must manage DNS data through an authenticated management API. Management is the sole writable source of truth for managed zones; servers serve durable, published replicas without depending on management availability for queries or recovery from a node restart.

The smallest functional milestone is deliberately narrower than v1:

> Create and publish one complete zone through the management API; one real Server Agent installs it; UDP and TCP queries return its records; stop management and restart the DNS server; the published zone still works.

Implement this path before four-node orchestration or UI work. A single-node milestone is not permission to deploy an incomplete DNS implementation publicly.

The reviewed report is historical input, not a guarantee about the present checkout. Start by recording HEAD and validating its findings. Do not reset the repository to the reviewed commit, redo fixes already present, or claim baseline failures remain without reproducing them.

## 2. Decisions and non-negotiable invariants

| Area | v1 decision |
|---|---|
| Topology | One management instance and four independent Server runtimes. Netman is not in the DNS distribution path. |
| Ownership | Management owns editable Zone/RRset data. Node inventories and UI caches are observations, not competing desired state. |
| Query path | Queries use the node's installed local state. No management RPC or cross-node consensus per query. |
| Distribution | Reuse the Server Agent's authenticated, outbound management connection. Notifications trigger reconciliation; they are not the only durable record of work. |
| Configuration boundary | DNS manifests have their own lifecycle, independent of service configuration versions. |
| Publication | Publish complete, immutable ZoneVersions, not loops of online per-record commands against four servers. |
| Consistency | Atomic activation within each zone; eventual convergence across nodes. No simultaneous four-node cutover promise. No cross-zone transaction promise. |
| Persistence | A successful draft edit is durable. Publication is accepted only after its complete intent is recoverable. A node reports applied only after durable installation, activation and local checks. |
| Failure behavior | Invalid or incomplete updates preserve the last valid zone. An offline control plane does not erase local data. |
| Managed writes | Existing local record APIs, UI actions, dynamic updates and provider sync may not mutate a management-owned zone. Preserve explicitly unmanaged behavior where compatible. |
| Runtime | Authoritative-only mode. Disable recursion, forwarding and unrelated listeners. Unknown zones follow an explicit refusal policy. |
| Implementation | Functional domain transformations and explicit error results. OTP processes own I/O, state and coordination. No broad umbrella rewrite. |

Exactly four is a deployment acceptance target, not a constant to bake into the reconciler. A simple explicit target list must support the one-node milestone and the four-node release without adding a scheduler or a generic Node domain model.

### Out of scope

Do not make DHCP, NetBoot, Netman changes, DNSSEC signing, AXFR/IXFR interoperability, dynamic DNS updates, recursive resolution, external DNS provider integration, Anycast, GeoDNS, multi-tenant billing, multi-region management HA or a redesigned UI prerequisites. Do not introduce a broker, database migration, Kubernetes dependency, new umbrella application or storage backend replacement without a demonstrated need and compliance with repository instructions.

Unsupported record types and operations must fail explicitly rather than be accepted and silently ignored. If child delegation is not implemented correctly, reject non-apex NS data in managed zones. Standard parent delegation of the hosted zone remains part of deployment.

## 3. Component boundaries

These are starting points from the reviewed snapshot; verify the actual layout before editing.

| Component | Intended ownership |
|---|---|
| `yellow_dog_management_core` | DNS domain operations, drafts, immutable versions, placements, publication commits, audit, desired manifests, deployment reconciliation. |
| `yellow_dog_console` | Thin HTTP controllers, authentication/authorization, request parsing and response presentation; existing secure Agent transport adapters. No separate DNS source of truth. |
| `yellow_dog_sync` | Versioned DNS wire contract, validation and compatibility negotiation. No runtime storage or UI dependencies. |
| `yellow_dog_server_agent` | Fetch/receive desired DNS state, fencing, retry/reconnect behavior, installation coordination and observed-state reporting. |
| `yellow_dog_dns` | DNS semantic validation where appropriate, immutable query indexes, atomic activation, authoritative packet behavior. |
| `yellow_dog_store` | Existing node-side persistence integration where appropriate; not the cloud DNS master database. |
| Runtime/release configuration | Authoritative profile, data paths, enabled listeners, independent restart, credentials and release packaging. |

Reuse existing pure DNS types and codecs where suitable. Share wire types through the existing shared boundary; do not make Management depend on starting the DNS server. Do not move unrelated modules merely to make the new feature look architecturally uniform.

## 4. Data and version contracts

| Entity | Minimum semantics |
|---|---|
| Zone | Stable ID, canonical apex, editable revision, lifecycle and SOA/NS settings. |
| RRset | `(zone_id, owner, class=IN, type)`, one TTL, typed RDATA collection. Replace/delete a whole RRset. |
| ZoneVersion | Immutable full zone payload, schema version, zone version, SOA serial, deterministic digest and publication metadata. |
| Placement | Explicit target Server IDs, initially one target for the milestone and four for v1. |
| Server DNS manifest | Authenticated target identity, monotonic manifest generation, complete map of management-owned zones to versions/digests. |
| Deployment | Stable ID, immutable publication intent, selected draft revision, target-set snapshot, request idempotency identity and timestamps. |
| DeploymentTarget | Expected manifest/zone identity, observed installed identity, retry information, structured error and verification evidence. |
| Audit event | Actor, request ID, affected zone, operation, revisions/versions, outcome and time; no secrets. |

Keep these four counters distinct: draft revision, immutable zone version, SOA serial and per-server DNS manifest generation. Rollback restores old content in a NEW ZoneVersion with a new SOA serial; it never asks the agent to accept an older manifest generation.

Normalize domain-name fields consistently. Preserve data whose bytes and ordering matter, including TXT content and TXT segment order. Deduplicate unordered RRset members and define deterministic serialization before hashing. The digest must cover the agreed immutable payload, including its schema and relevant zone/version identity; transport timestamps and delivery-attempt IDs must not change it. Hashing must not depend on map iteration order.

For the first functional milestone, A, NS and SOA are sufficient if the API clearly rejects other types. The complete v1 gate requires A, AAAA, NS, SOA, CNAME, MX and TXT. SRV, CAA and PTR can be added in the same validation framework but are not a reason to delay the first end-to-end path. Management owns the published SOA serial; callers may not bypass its allocator.

## 5. Persistence, fencing and recovery

### 5.1 Management commit

A publication must commit an immutable snapshot and enough authoritative metadata to reconstruct its desired-state change, deployment targets, idempotency result and audit linkage after a crash. Derived per-server manifests and work queues may be rebuilt from committed intent; they must not be the only copy of that intent.

Reuse the existing durable version/manifest pattern if it can enforce this. A single committed manifest or journal record can serve as the commit point, with materialized indexes treated as recoverable projections. Otherwise, document a narrowly scoped persistence change. Do not assume several independent file writes form a transaction.

No `202 Accepted` before the recoverable commit. A process crash immediately after commit but before HTTP response must allow an idempotent retry to recover the original deployment rather than create another serial/version.

Serialize updates to shared desired-state metadata or use explicit compare-and-swap. Concurrent publication of Zone A and Zone B onto the same server must preserve both changes. Per-zone optimistic locking alone is insufficient to protect a shared per-server manifest.

### 5.2 Node installation

Use an explicit state machine for validation, candidate persistence, index construction, activation and acknowledgement. Specify recovery at every boundary; the exact order must match the chosen persistence primitive.

The implementation must provide all of the following properties:

- Validate target identity, schema, capacity, complete-zone semantics, digest and generation before activation.
- Stage candidate data without clearing or incrementally mutating the active index. Preserve old immutable data until no in-flight query can use it.
- Persist the candidate and a crash-recoverable active-version transition. Handle write, flush, rename and filesystem errors according to a documented durability model.
- Activate a complete candidate only after validation; failure must preserve or recover the previous complete version. Queries during installation must see a complete old or new version, not a partially rebuilt zone.
- Report applied only after durable activation and local DNS checks. A failed health check must not leave a false durable success marker.
- Resend observed installed state after a lost acknowledgement or reconnect; duplicate delivery is safe.
- Fence both receipt and final activation so a slow older worker cannot overwrite a newer desired state. Reject a reused generation with a different manifest digest.

Store desired/received and installed/applied state separately. Receiving a new manifest is not proof all of its zones were installed. Do not report a manifest fully applied while some resources remain old or failed.

### 5.3 Reconciliation and deletion

The desired manifest is the complete management-owned set. On reconnect and on a bounded periodic interval, compare actual installed state with the current desired set, fetch missing immutable content, activate updates and remove zones absent from the desired set. Never remove unrelated unmanaged zones based on an incomplete or unauthenticated message.

A deletion must be recoverable from durable desired state. Delete RRsets through a new zone snapshot. Delete a zone by publishing a tracked removal and removing it from desired membership. An offline node must not resurrect that zone when it returns. Acknowledgement of removal follows durable membership change and runtime deactivation, not just request receipt.

For a node managing several zones, valid independent updates may apply while another zone fails; record that partial progress explicitly. Multi-zone atomicity is not a v1 guarantee.

### 5.4 Supersession and restore

Current desired state wins over delivery order. Superseded deployments retain their original version, targets and historical evidence; late acknowledgements cannot turn an older deployment into current success. Retryable failures keep reconciling with bounded backoff and jitter. A deadline or UI failure label is not implicit permission to discard desired state.

A restored management backup may be older than node state. Detect this and preserve serving nodes; do not disable stale-generation checks or silently republish old data. The recovery runbook must describe how an operator selects the authoritative restored content and safely re-establishes generation/serial high-water marks before publication resumes. A tested fresh-host restore is a release gate; any unsupported stale-backup recovery path must fail closed and be explicitly documented.

## 6. Management API contract

Paths below are proposed. Adapt naming only where the repository has an established convention; preserve the semantics.

| Method and path | Required behavior |
|---|---|
| `POST /api/v1/zones` | Create a durable draft with explicit target placement and valid zone identity. |
| `GET /api/v1/zones` | List management-owned zones; define pagination or an explicit bounded limit. |
| `GET /api/v1/zones/:id` | Return draft revision, published version and placement. |
| `GET /api/v1/zones/:id/rrsets` | Return canonical management data, not live queries against one node. |
| `PATCH /api/v1/zones/:id/rrsets` | Apply a bounded batch of whole-RRset replacements/deletions against `expected_revision`; all-or-nothing draft edit. |
| `POST /api/v1/zones/:id/publish` | Publish exactly the requested draft revision and return a durable deployment ID. |
| `GET /api/v1/deployments/:id` | Return expected/observed versions, target progress, errors and separate verification evidence. |
| `GET /api/v1/servers` | Show existing enrolled servers and DNS capability/observed status; reuse existing enrollment. |
| `POST /api/v1/zones/:id/rollback` | Publish selected historical content as a new version and new SOA serial. |
| `DELETE /api/v1/zones/:id` | Accept a tracked removal deployment; retain the history required for offline cleanup. |

Saving a draft is not publishing. Publish must include `expected_revision`. Stale revisions and idempotency-key reuse with a different request return `409`; invalid zone semantics return `422`; oversized requests return `413`; unauthenticated and forbidden operations remain distinct. Successful publish and delete acceptance return `202`, not a claim of four-node completion.

Persist idempotency results for mutations where retries could duplicate effects. Scope keys to authenticated actor, endpoint/operation and request identity; define the retention window. Same key and same request recover the original result, including after management restart.

Use existing authentication facilities where suitable, but explicitly separate operator API tokens, browser sessions and node credentials. Apply read/write/publish permissions, bind node identity to server ID, support credential revocation/rotation, verify TLS and redact credentials from logs. Keep controllers thin and publish an OpenAPI contract with runnable API integration tests.

## 7. Milestones and reviewable changes

### M0 — Verify the baseline and freeze the contracts

**Work:** Read repository instructions, record HEAD, inspect relevant apps and test/release aliases, run existing quality gates, and reproduce relevant review findings. Write a concise ADR covering ownership, version spaces, commit points, reconciliation, managed/unmanaged coexistence and supported DNS subset. Identify a DNS-specific CI gate that runs independently of unrelated app failures.

**Exit gate:** The baseline records commands and outcomes, not assumptions; contracts are explicit; relevant failing regressions have tests. Do not skip unrelated failures or fix them by weakening assertions. Keep narrowly justified baseline fixes separate.

**Suggested change:** `test(dns): establish authoritative v1 baseline and contracts`.

### M1 — Deliver the durable single-node vertical slice

**Work:** Implement minimal Zone/RRset storage, pure validation, revisions, immutable snapshots, serial allocation, placement and durable publication. Add the authenticated API subset for create/read/edit/publish/status. Add an independent DNS manifest and connect it through the existing real Agent transport to a durable snapshot installer. Enforce authoritative-only runtime and management ownership for the installed zone.

Use one configured server and one complete zone with SOA, NS and A data in the acceptance fixture. Avoid hardcoding that cardinality into domain or protocol structures. Include retry after disconnect, lost-ack recovery and management/node restart behavior even at this milestone.

**Exit gate:** Through HTTP create `example.test.`, publish a known revision, verify A/NS/SOA over UDP and TCP on a separate release process, stop management, restart the DNS server using its persistent directory and verify the same data. Reconnect management and recover actual applied status without another edit. An invalid snapshot or write error leaves the prior zone available and never reports applied.

**Suggested reviewable changes:**

1. `feat(management): add durable DNS zones and publication commits`
2. `feat(api): expose management-owned DNS draft and publish endpoints`
3. `feat(agent): install durable DNS snapshots and prove single-node recovery`

These are one milestone, not permission to stop after models and controllers. Finish the real transport and network-query test before declaring M1 done.

### M2 — Complete authoritative DNS behavior and input validation

**Work:** Add the required v1 RR types and full-zone checks, protocol regressions and resource bounds. Revalidate and fix the reviewed wildcard/empty-non-terminal behavior rather than assuming it still exists. Verify CNAME conflicts/chains/loops, SOA and apex NS rules, names within the zone, negative answers and TTLs, AA/RA flags, unsupported operation responses, EDNS, truncation and TCP handling.

Do not fall back to forwarding or recursive resolution for missing names or external CNAME targets. Support zone-cut/referral semantics correctly or reject unsupported child delegations at the API. Ensure managed-zone local mutations cannot bypass the new source of truth.

**Exit gate:** Table-driven domain tests plus actual wire-query tests pass for positive/negative answers, CNAME, wildcard, empty non-terminals, no-recursion policy, large responses and UDP/TCP. Regression tests accompany every confirmed fix.

**Suggested change:** `fix(dns): enforce authoritative semantics and safe managed-zone updates`.

### M3 — Converge four nodes and complete the lifecycle

**Work:** Materialize independent desired manifests for four enrolled servers, reconcile at startup/reconnect/periodic intervals, retain durable retries, expose partial status, and validate acknowledgement identity against expected version/digest/generation. Add tracked zone removal, RRset deletion, rollback with new serial, supersession and safe placement change. Serialize concurrent desired-state updates so different zones are never lost.

**Exit gate:** Four independent runtime processes converge to the same ZoneVersion/digest/SOA serial. Disconnect only node four's management connection while leaving its DNS listener running: the next publish yields visible 3/4 progress, and node four catches up automatically after reconnect. Deletion, rollback, management restart midway through dispatch, duplicate/stale messages and concurrent two-zone changes all pass. Service configuration updates do not erase DNS desired state.

**Suggested changes:**

1. `feat(management): reconcile DNS deployments across independent servers`
2. `feat(dns): add tracked deletion rollback and supersession`

### M4 — Produce deployment artifacts and prove v1

**Work:** Build pinned production releases for one management instance and four independent DNS nodes with distinct identities and persistent volumes. Reuse the repository's deployment convention and Nix/devenv tooling where present. Provide one supported deployment path, not several unfinished alternatives. Add listener-boundary checks, TLS/bootstrap guidance, minimal privileges for port 53, resource limits, readiness/liveness, metrics, structured audit/logs, backup/restore and staged upgrade procedures.

**Exit gate:** Release-level CI runs the complete four-node acceptance suite. A clean environment can follow the runbook using only API actions to manage data. Perform a fresh-host management restore and a node rebuild with retained data. Record load-test environment and results without inventing capacity guarantees. Keep local/container evidence separate from actual public-host evidence.

**Suggested changes:**

1. `test(e2e): verify four-node DNS convergence and crash recovery`
2. `chore(release): package authoritative DNS v1 and operational runbooks`

A minimal status UI is optional after these gates, and must consume the same domain operations. It is not on the critical path.

## 8. Deployment status and health model

Expose `accepted`, `distributing`, `partial`, `applied`, `failed` or `superseded` reconciliation state using documented aggregation rules. Keep per-target errors and retries visible even when the aggregate is partial. Offline is a connectivity observation, not proof a DNS listener is unhealthy.

Store independent verification results with their timestamp, queried node, expected version/serial and observed answers. Only display `verified` for a specific publication after independent UDP/TCP checks; do not promote an Agent acknowledgement into network verification. A successful network probe samples behavior; it is not a cryptographic proof that every RRset was queried.

Separate process liveness, ability to serve installed DNS data, and freshness against desired state. Loss of management connectivity must not make healthy serving nodes restart repeatedly. A new unconfigured node must not claim serving readiness using demo zones; a deliberately acknowledged empty desired set is a distinct supported state.

## 9. Acceptance matrix

| ID | Test | Pass condition |
|---|---|---|
| A01 | Management with all agents offline | Draft creation/edit and publication acceptance are durable; target state remains pending/offline. |
| A02 | Competing draft edits | Exactly one write wins a matching expected revision; the other gets a conflict. |
| A03 | Repeated mutation/publish request | Same idempotency key/body recovers the original result across restart; a changed body conflicts. |
| A04 | One-node vertical slice | Real HTTP → real Agent connection → durable install → UDP/TCP answers. |
| A05 | Management down, DNS node restarted | Last valid zone loads locally and continues serving without management. |
| A06 | Rejected candidate / filesystem failure | Old complete zone survives; no false applied result. |
| A07 | Kill at installation boundaries | Restart recovers complete old or new state, never a half-zone or empty replacement. |
| A08 | Query during installation | Each response is internally consistent with an old or new zone snapshot. |
| A09 | Four-node online publication | All nodes report the intended version/digest and independently answer with matching data/serial. |
| A10 | Management partition on one serving node | Publication is visibly partial; node keeps old data; reconnect converges automatically. |
| A11 | Delete while one node is offline | Returning node removes deleted records/zone and does not resurrect them. |
| A12 | Management killed during dispatch | Committed intent survives and remaining targets reconcile without another API publish. |
| A13 | Duplicate/stale/out-of-order delivery | Idempotent handling, final-activation fencing and no acknowledgement regression. |
| A14 | Lost acknowledgement | Reconnect inventory restores matching applied status without inventing success. |
| A15 | Concurrent Zone A, Zone B and service config changes | Both DNS changes survive; service configuration and DNS heads remain independent. |
| A16 | Rollback and supersession | Old content receives new version/serial; old work cannot replace current desired state. |
| A17 | DNS wire correctness | Required types, wildcard/ENT, positive/negative responses, CNAME, EDNS, truncation and TCP pass. |
| A18 | Credentials and protocol misuse | Unauthorized API, wrong node identity, revoked credentials, untrusted TLS and unsupported writes fail. |
| A19 | Process/listener boundary | Management does not expose DNS/DHCP listeners; DNS nodes expose no unintended services or public Erlang distribution. |
| A20 | Backup restore and upgrade | Supported restore path and node restart/upgrade preserve data and reconcile; stale-backup conflicts fail safely. |
| A21 | Public deployment checklist | Parent NS, necessary glue, relevant DS/DNSSEC migration state, IPv4/IPv6 and UDP/TCP reachability verified where actually deployed. |
| A22 | Bounded resource behavior | Request/snapshot size, query/TCP limits and measured performance documented for the tested environment. |

Use deterministic synchronization and bounded waits in tests. Do not replace assertions with sleeps or skip the tests that reveal races. Use fault injection at persistence and transport boundaries and separate release processes or containers, not four logical GenServers in one VM as the only evidence.

## 10. Operational deliverables

The runbook must identify immutable release/manifest digests, configuration and persistent paths, enrollment/rotation, API credentials, safe TLS bootstrap, required ports, listener ownership and network reachability. DNS nodes should need no public management socket. Do not expose EPMD or unauthenticated distributed Erlang as the control protocol.

Provide metrics or structured events for query errors/latency, listener health, desired-versus-applied versions, failed installation reasons, last successful reconciliation, disk pressure and backup status. Make stale serving data visible rather than calling a node offline and ignoring it.

Document parent-zone delegation and necessary glue, inspect DS records before migrating a signed domain, and avoid a bootstrap loop where the node needs its unpublished zone to resolve the management hostname. Do not claim public DNS readiness from an internal container test alone.

## 11. Definition of done and handoff

For every reviewable change, record the current commit, changed modules, the requirement addressed, exact commands executed, results and any unexecuted checks. New tests must assert failure behavior and recovery, not only happy-path HTTP responses.

M1 is complete only when the single-node release-level recovery test passes. v1 is complete only after M2–M4 pass and the four-node deployment is reproducible. A missing runtime, network capability or credential is a reported verification blocker, not a test pass. Existing unrelated failures remain visible; no broad cleanup is justified merely to make the report look green.

## 12. Source and verification boundary

This plan derives from the accompanying `yellow-dog-authoritative-dns-v1-review-20260924.md`, particularly sections 2–7 and 9. That review identifies the baseline commit and provides immutable source links. It did not execute the project's tests, deployment or benchmark suite. New contracts in this plan are recommendations, not statements that the repository already implements them.

Protocol work should use the primary standards cited in that report: RFC 4592 (wildcards and empty non-terminals), RFC 2308 (negative answers/caching), RFC 9210 (DNS transport operations) and RFC 1982 (SOA serial arithmetic), together with relevant base DNS specifications. Recheck the actual implementation and applicable standards when writing tests.
