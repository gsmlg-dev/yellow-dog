# Management HTTP and MCP contract

Final combined-source commands, results, artifact hashes and unexecuted checks are
recorded in the [Step 3/4 acceptance report](management-step4-acceptance.md).

The HTTP API uses OpenAPI 3.1.2. MCP uses protocol 2025-11-25 and the pinned JavaScript SDK 1.32.1. Both adapters call ApplicationAPI with a verified Caller. Management is a resource server; external authentication and explicitly enabled loopback development mode are owned by the common policy boundary. Adapters are disabled by default.

See [integration security](management-integration-security.md) for exact deployment settings,
JWT/gateway trust, session lifetime, permissions, limits and legacy-route behavior, and
[Management MCP](management-mcp.md) for the pinned client and cross-entry integration gate.

The finite operation matrix below is the implementation checklist. Paths have prefix `/api/v1`. Each operation has a closed JSON Schema 2020-12 input and explicit output schema in `Operations`; those exact maps feed runtime JSV validation, OpenAPI and MCP. Request identities come from HTTP `Idempotency-Key` or MCP `logical_request_key`, never from JSON-RPC IDs. All commands require a logical key. Reads have no effects. Errors use `code`, `message`, optional `details`, and a separate `correlation_id` envelope. No input permits actor, scope, provider URL, credential or filesystem path.

| Operation / MCP tool | HTTP method and path | Scope | Concurrency |
| --- | --- | --- | --- |
| worker_list | GET /workers | config:read | — |
| worker_get | GET /workers/:worker_id | config:read | — |
| worker_update | PATCH /workers/:worker_id | nodes:write | expected_revision |
| service_list | GET /workers/:worker_id/services | config:read | — |
| service_get | GET /workers/:worker_id/services/:service_id | config:read | — |
| service_references | GET /workers/:worker_id/services/:service_id/references | config:read | — |
| service_create | POST /workers/:worker_id/services | nodes:write | expected_revision (Worker) |
| service_update | PATCH /workers/:worker_id/services/:service_id | nodes:write | expected_revision (Worker) |
| zone_list | GET /zones | config:read | — |
| zone_get | GET /zones/:id | config:read | — |
| zone_versions | GET /zones/:zone_id/versions | config:read | — |
| zone_version_get | GET /zones/:zone_id/versions/:version_id | config:read | — |
| zone_assignments | GET /zones/:zone_id/assignments | config:read | — |
| zone_create | POST /zones | data:write | new draft |
| zone_update | PATCH /zones/:id | data:write | expected_revision |
| zone_delete | DELETE /zones/:id | data:write | expected_revision |
| zone_confirm | POST /zones/:id/confirm | data:write | expected_revision |
| zone_set_assignments | PUT /zones/:zone_id/assignments | data:write | expected_assignment_token + expected_worker_revisions |
| dns_view_list | GET /workers/:worker_id/dns-services/:service_id/views | config:read | — |
| dns_view_get | GET /workers/:worker_id/dns-services/:service_id/views/:id | config:read | — |
| dns_view_create | POST /workers/:worker_id/dns-services/:service_id/views | data:write | new scoped View |
| dns_view_update | PATCH /workers/:worker_id/dns-services/:service_id/views/:id | data:write | expected_revision |
| dns_view_delete | DELETE /workers/:worker_id/dns-services/:service_id/views/:id | data:write | expected_revision; default protected |
| dns_acl_list | GET /workers/:worker_id/dns-services/:service_id/acls | config:read | — |
| dns_acl_get | GET /workers/:worker_id/dns-services/:service_id/acls/:id | config:read | — |
| dns_acl_create | POST /workers/:worker_id/dns-services/:service_id/acls | data:write | new scoped ACL |
| dns_acl_update | PATCH /workers/:worker_id/dns-services/:service_id/acls/:id | data:write | expected_revision |
| dns_acl_delete | DELETE /workers/:worker_id/dns-services/:service_id/acls/:id | data:write | expected_revision |
| worker_target_preview | GET /workers/:worker_id/target-preview | config:read | returns reviewed Worker revision |
| worker_target_history | GET /workers/:worker_id/targets | config:read | — |
| worker_target_get | GET /workers/:worker_id/targets/:revision | config:read | exact immutable revision |
| worker_target_export | GET /workers/:worker_id/targets/:revision/export | config:read | exact immutable revision |
| worker_target_publish | POST /workers/:worker_id/targets | targets:publish | expected_revision (reviewed Worker) |
| task_list | GET /tasks | config:read | supported City/Country only |
| task_get | GET /tasks/:key | config:read | — |
| task_update | PATCH /tasks/:key | sync:settings | expected_revision |
| task_jobs | GET /task-jobs | config:read | optional supported key filter |
| task_job_get | GET /tasks/:key/jobs/:job_id | config:read | exact persistent job identity |
| ip_database_catalog | GET /ip-databases/:kind/artifacts | config:read | selected metadata included independently |
| ip_database_artifact | GET /ip-databases/:kind/artifacts/:digest | config:read | exact metadata; no byte verification |
| ip_database_sync | POST /ip-databases/:key/sync | sync:run | queues existing task, returns job ID |
| audit_list | GET /audit | audit:read | redacted metadata only |

Lists use stable SQL ordering, page default 1, page_size default 20/max100, page max100000, and has_next lookahead. List projections exclude historical plans, full rule sets, provider URLs, job args/errors and audit request/result payloads. Exact details remain bounded by domain limits. The complete assignment snapshot has a hard 256-assignment limit and is never paginated or silently truncated. Assignment edits require concurrency revisions for the union of existing and submitted Workers; fetch added candidates with worker_get.

HTTP path identities are authoritative; contradictory JSON identities fail. Missing/invalid authentication is 401, permission denial403, unknown object404, conflict409, malformed request400, business validation422, oversized input413, rate limiting429, and unavailable database/adapters503. No error exposes stack traces or SQL. Reauthorization occurs before reads/replay and inside the receipt-lock transaction. Same principal/client/key/canonical operation/payload replays across HTTP and MCP; different payload conflicts. Corrected input or reviewed conflicts require a new logical key.

Logical keys contain 1–128 bytes. The stored receipt key is `r1:` plus unpadded
base64url SHA-256 of the JSON array (46 characters total)
`["management-request-v1", issuer, subject, client_id_or_null, logical_key]`.
This bounded encoding fits the existing receipt column. Transport source,
correlation ID, token lifetime and operation are excluded from the namespace;
the receipt fingerprint independently checks operation and canonical payload.
Replaying a receipt retains its original audit entry and verified source.

Saving drafts, confirming a Zone, replacing assignments and publishing a Worker target are separate commands. Publication never occurs implicitly. Current target scope is DNS service settings plus confirmed DNS Zones; Views, ACLs and IP database artifacts remain configured-only and are excluded. Actual Worker application remains unknown absent a separately authenticated observation. Queued/completed sync state does not prove artifact byte availability; metadata reads report verification unknown.

Remote credential issuance/rotation, enrollment policy, backup operations, runtime actions, arbitrary task/provider URLs, deployment settings are deliberately excluded. WorkerAPI is separate and unchanged. The finite registry offers no arbitrary command dispatcher.

## Contract generation and validation

The checked artifact is `docs/phase1/management-openapi.json`. The HTTP endpoint `/api/v1/openapi.json` generates the same document. Each matrix operation ID selects its request schema (`Operations.get(id).input_schema`) and result schema (`Operations.get(id).output_schema`); OpenAPI uses these maps directly with transport path parameters and response envelopes. Required concurrency fields appear in each command's closed input schema.

Run `devenv shell -- env MIX_ENV=test scripts/e2e/management_openapi.sh --check` (or `npm run openapi:validate` inside the prepared toolchain). The script generates a temporary document without starting Management or PostgreSQL, validates OpenAPI 3.1.2 with pinned `@redocly/cli` 2.69.0's specification rules, then compares parsed JSON with the checked artifact. After an intentional registry change, regenerate with `--write` and review the artifact diff. Runtime JSV 0.26.1 validates the same JSON Schema 2020-12 inputs and result maps; no schema uses remote references.

Both adapters return `{"data": ..., "correlation_id": "..."}` for successful operations and `{"error": {"code": "...", "message": "...", "details": ...}, "correlation_id": "..."}` for failures. HTTP accepts a single `application/json` Content-Type with UTF-8 charset; misleading JSON prefixes and other charsets fail before mutation. Worker update binds the route's `worker_id` to canonical Domain input `id`. All path identities remain authoritative. Every command requires an Idempotency-Key of 1..128 bytes; all reads are side-effect-free. Integration admission allows at most 32 concurrent facade calls and 10 sync admissions per principal per minute.

## Projections and verification evidence

Server-built LiveView commands use the same finite operation registry,
authorization, caller/client key namespace, transaction and output validation.
Their route-owned identities and parsed form fields are already assembled by the
UI adapters. The UI entry rejects unknown top-level fields and leaves semantic
validation to Domain so invalid business submissions retain their existing cached
error/audit behavior and editor lifecycle. HTTP and MCP additionally validate the
complete wire input schema before dispatch. Correcting a cached business error
requires a new logical request key in every entry path.

The shared facade authorizes before resource reads or receipt replay, validates closed inputs through JSV, delegates commands to the existing transaction boundary and validates canonical command output before commit. Read results validate after projection. Worker catalogs omit credential hashes and raw report/error fields. View/ACL catalogs omit rule payloads; exact scoped details retain domain protections. Version/target history catalogs omit immutable bodies. Job projections omit args, raw errors and receipt bodies. Artifact projections omit local paths, source credentials/URLs and arbitrary metadata, and explicitly report unknown byte verification. Remote audit catalogs expose identity/operation/time metadata; UI audit tests verify hashed principals, verified UI context and redacted request contents.

The scoped acceptance command is `scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management test test/application_api_test.exs test/worker_submission_live_test.exs test/zone_import_live_test.exs test/tasks_live_test.exs`, executed inside devenv. It passed 50 tests with 0 failures, including all 42 facade operations, cross-adapter replay, publication identity/revision preservation, schema field paths, bounded paging, wrong ownership, actual HTTP Worker PATCH, misleading media types and existing UI submission lifecycles. Real Redocly validation passed against the generated 3.1.2 artifact. Broader integration/security/runtime gates are tracked separately.

The View fallback endpoint contract preserves existing IPv4 and IPv6 configuration, including compressed/full IPv6 and IPv4-embedded IPv6 strings. Domain canonicalization preserves endpoint order and duplicates, ordered client rules, explicit empty network rules, and zero-rule configuration. Only View fallback addresses use this union; DNS service listeners, A records and WorkerPlan remain IPv4-only. API plus existing DNS View Domain/LiveView regressions passed 55 tests with 0 failures after this reconciliation. API rollback/replay/media-type tests compare effect counts with their starting database state and verify exact Zone identities, so unrelated fixture Zones do not invalidate side-effect checks.
