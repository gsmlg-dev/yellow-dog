# ADR: Management-owned authoritative DNS publication

**Status:** Accepted for M1 implementation  
**Date:** 2026-09-28  
**Scope:** One Management runtime and one independently restarted Server runtime

## Decision

Management is the only editor for managed zones. A draft edit changes a durable draft revision; publishing selects exactly that revision and allocates a new immutable zone version and SOA serial. Publication acceptance means the immutable content, target snapshot, deployment identity, idempotency result and desired-state change can be recovered from durable Management storage. An Agent being online is not a prerequisite.

Each Server has a DNS manifest generation independent of its service-configuration version. A manifest contains the complete managed zone set for that target and immutable content digests. Management serializes changes to a target's desired set so publishing another zone cannot discard the first. The authenticated outbound Server Agent reconciles on startup, reconnect and a bounded timer. Notification only accelerates this process.

The Server validates and stages a complete candidate before changing its active query index. It syncs a pending marker containing the previous manifest before activation, then syncs the new active file, a last-valid copy and an applied marker. Removing the pending marker completes the commit. Startup rolls back an interrupted transition or repairs a corrupt active file from the last-valid copy. Runtime activation is an atomic switch between complete indexes; installed acknowledgement follows persistence, activation and routed local checks. Queries use local state and do not depend on Management connectivity. Receipt, installed state and independent DNS verification remain separate observations.

The managed ownership boundary rejects legacy local, UI and provider writes to the same zone. Explicitly unmanaged zones retain their existing behavior. M1 accepts only complete `IN` zones using apex SOA and NS plus A RRsets; unsupported types, child NS delegation and invalid candidates fail explicitly. Authoritative-only profile disables forwarding and recursion and starts without demo zones.

The production Management HTTP listener binds only to IPv4 loopback; a local TLS terminator exposes the API and Server WebSocket externally. Server credentials are derived per enrolled ID using HMAC-SHA256 over `"yellow-dog-server:" <> server_id` with the Management provisioning secret, then unpadded base64url encoding. A Server receives only its derived token. The operator API token is separate, and the outbound Agent verifies the TLS peer. Rotating the provisioning secret revokes all derived Server credentials; finer rotation is outside M1.

## Version spaces and failure behavior

Draft revision, zone version, SOA serial and per-Server DNS manifest generation are distinct monotonic values. Repeated delivery of the same generation and digest is idempotent; the same generation with different content is invalid; lower generations cannot activate. Invalid content or a failed write preserves the last complete installed zone. Recovery after a crash uses the durable activation record, and a reconnect reports actual installed state so lost acknowledgement can be repaired.

M1 promises atomic activation of a single zone and eventual convergence of one Server. It does not promise simultaneous multi-Server cutover or cross-zone transactions. Full RR-type semantics, wildcard and empty-non-terminal behavior, four-node convergence, removal, rollback and operational restore gates remain M2–M4 work.

## Milestone checklist

- [x] M0: record current HEAD and inspect repository contracts and release harness.
- [x] M0: record outcomes of pinned compile, format, scoped tests and relevant existing E2E checks.
- [x] M1: durable draft and publication, authenticated HTTP API, and independent manifest.
- [x] M1: real Agent reconciliation and durable non-destructive Server activation.
- [x] M1: separate-process HTTP to Agent to UDP/TCP test, offline Server restart, and Management reconnect recovery.
- [x] M1: invalid, stale, duplicate, lost-ack and persistence-failure regressions pass.

## M0 baseline observations at `bfc70f89693587b7b6b4886d78839839bbc7c75f`

The checkout initially contained only the supplied untracked implementation plan. Its existing `command_server` path is online-only; the service configuration publication stream uses `config_version` and has no DNS manifest. `Auth.reload/2` clears the active ETS table before loading replacement content, and zone import starts an asynchronous Store write without waiting for success. Those paths cannot be used as the managed publication commit point. The managed installer and independent manifest address the M1 risks without changing unmanaged behavior. The existing wildcard candidate picks a single suffix and `name_exists?` checks stored names; the full closest-encloser and empty-non-terminal audit belongs to M2.

`devenv shell mix compile --warnings-as-errors` failed at baseline on existing separated `handle_call/3` clauses in `apps/yellow_dog_dns/lib/yellow_dog/dns/zone/auth.ex`. This is a compiler warning promoted to an error; it is not a DNS test failure. A format check launched after parallel editing began and is not baseline evidence.

## Verification after M1 implementation

`devenv shell mix compile --warnings-as-errors` and `devenv shell mix format --check-formatted` pass. The existing `devenv shell mix test.e2e.dns` gate passed 103 tests with 19 excluded; it emitted E2E compiler warnings and telemetry handler teardown errors despite exit status 0. `devenv shell mix test.e2e.management` passed two tests, including the separate-release HTTP, Agent, UDP/TCP, Server-offline publication and catch-up, Management-offline Server restart and Management reconnect path. An initial rerun failed because the fixture changed Server ID without deriving a new ID-bound credential; the corrected rerun passed. The shared test data directory can exhaust the Server registry and cause socket tests to fail with `:registry_full`; an isolated `YELLOW_DOG_DATA_DIR` passed all six ServerSocket tests. Scoped Management (6), DNS API (2), Channel (18), DNS snapshot (11), Sync, Agent, Store and legacy-control tests passed in their application contexts. An out-of-scope Boot controller test returns `:invalid_transition` both in its suite and in isolation; no Boot code was changed.
