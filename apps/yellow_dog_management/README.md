# Independent Yellow Dog Management (Phase 1 Track A)

Management owns editable DNS data in PostgreSQL. It prepares complete configuration
for logical allocation targets; it neither contacts nor starts a Worker. There is
no legacy import, dual write, delivery loop, or fake runtime observation.

## Shared baseline prerequisite

This checkout did not contain C0 at `61a447a3e1ae4e80da3800054807e0a0abf1b0a5`.
The shared-file owner must integrate `docs/phase1/config-spec.patch` (the single
proposed ConfigSpec contract) and `docs/phase1/management-build.patch` (root release
and dependency lock additions). Both are handoffs, not silently applied changes.
Review this contract with Track B before integration. Never install a second
Management-only codec. The root release handoff deliberately retains legacy release
entries until the coordinated owner can integrate Worker and remove mixed entries.

For independent validation before shared integration, from the repository root:

```sh
docs/phase1/prepare-validation.sh /tmp/yellow-dog-track-a-validation
devenv shell -- bash -c 'cd /tmp/yellow-dog-track-a-validation/apps/yellow_dog_management && mix deps.get'
```

The assembly copies only Management and the proposed pure ConfigSpec. Subsequent
calls refresh sources without discarding dependency/build output. It never edits
Worker, root configuration, root lockfile, or an existing deployment.

## Run and migrate

Use a dedicated PostgreSQL database and a privileged operator token of at least
32 bytes. The single operator role has full read/write/export access. Logical Worker
IDs do not authenticate physical nodes. Authentication is required on every API
route; the browser holds the token only in memory and does not use auth cookies.
The public HTML shell contains no business data. The listener binds to loopback;
use an authenticated deployment's TLS reverse proxy for non-local browser access.

```sh
export YELLOW_DOG_MANAGEMENT_DATABASE_URL=postgres://postgres@127.0.0.1:5432/yellow_dog_management
export YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN='<at-least-32-byte-secret>'
export YELLOW_DOG_MANAGEMENT_PORT=4280
# From the app directory, inside the repository's devenv shell:
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix compile --warnings-as-errors
MIX_ENV=prod mix release yellow_dog_management
../../_build/prod/rel/yellow_dog_management/bin/yellow_dog_management eval 'YellowDog.Management.Release.migrate()'
../../_build/prod/rel/yellow_dog_management/bin/yellow_dog_management start
```

Open `http://127.0.0.1:4280`, sign in, create a complete SOA/NS/A zone, save and
confirm its version. This works with an empty Worker list. Then create any number
of logical Workers, define their DNS service instance, select an explicit version,
and check one or more Worker targets. Each selected Worker assignment is a separate
transaction; the UI reports how many completed if a later assignment fails.
Preview the complete target, confirm it, and download its selected revision.

The UI's record editor supports SOA, NS, and A only. Fully qualified names are
recommended. SOA value order is `mname rname serial refresh retry expire minimum`.
Service configuration is IPv4 `listen_address` and port 1–65535. Recursion, DNSSEC,
other record types, and other protocols are explicitly unsupported in C0.

## API

Send `Authorization: Bearer <token>` for all `/api` requests. All JSON mutations
use `POST /api/commands/<operation>` and require `Idempotency-Key: <1..128 bytes>`.
Success is `{"data": ...}`; failure is `{"error":{"code":...,"message":...,"details":...}}`.
Revision/idempotency conflicts return HTTP 409, missing data 404, invalid data 422,
malformed JSON 400, unauthorized 401, and oversized bodies 413 (1 MiB maximum).

Read routes:

- `GET /api/workers`, `/api/workers/:id` (includes services and assignments)
- `GET /api/zones`, `/api/zones/:id`, `/api/zones/:id/versions`
- `GET /api/workers/:id/preview` (complete next plan and previous-target diff)
- `GET /api/workers/:id/targets/:revision` (`latest` also accepted)
- `GET /api/workers/:id/targets/:revision/export` (TOML attachment)

Operations and required parameters:

| Operation | Parameters |
| --- | --- |
| `create_worker` | `id`, `name`, `expected_capabilities: ["dns"]` |
| `update_worker` | `id`, `expected_revision`, editable name/capabilities |
| `create_zone` | `name`, `records` |
| `update_zone` | `id`, `expected_revision`, `name`, complete `records` |
| `delete_zone`, `confirm_zone` | `id`, `expected_revision` |
| `put_service` | `worker_id`, `expected_revision`, `id` (instance ID), `type: "dns"`, `desired_state`, `config` |
| `assign` | `worker_id`, `expected_revision`, `service_id`, `resource_version_id` |
| `unassign` | `worker_id`, `expected_revision`, `service_id`, `resource_id` |
| `confirm_target` | `worker_id`, `expected_revision` |

For Worker operations, fetch the current Worker `revision`; it is the aggregate
compare-and-swap revision, separate from confirmed plan revision, Zone draft revision,
resource version, and SOA serial. Savepoint rollback persists a failed mutation's
idempotency outcome too. Retry the exact same request/key after a lost response;
use a new key for a corrected request. No key expiry is implemented in Phase 1.

For example, to confirm and export a selected prepared target:

```sh
curl --fail-with-body -H "Authorization: Bearer $YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN" \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: prepare-worker-one-r3' \
  -d '{"worker_id":"worker-one","expected_revision":3}' \
  http://127.0.0.1:4280/api/commands/confirm_target
curl --fail-with-body -H "Authorization: Bearer $YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN" \
  http://127.0.0.1:4280/api/workers/worker-one/targets/1/export > worker-one-1.toml
```

## Data and transaction boundaries

Relational tables cover Workers, services, Zones, RRsets, immutable resource
versions, assignments, immutable target plans, audit events, and idempotency outcomes.
RRset records are stored together by `(zone_id, name, type)` with one TTL. Immutable
content and complete confirmed targets use validated JSONB snapshots; editable
business data is not a giant JSONB store. Foreign keys and unique indexes constrain
relationships. PostgreSQL triggers prevent update/delete of confirmed versions and
targets, including direct SQL writes.

A mutation locks its idempotency row, then its aggregate rows, validates the complete
candidate, and commits business effects, audit, and durable response together. Zone
edits and Worker mutations require expected revisions. Conflicting concurrent edits
return an explicit conflict; the caller reloads and retries with a new key.

Assignments reference one immutable version, shared across Workers. A Zone cannot
be deleted while assigned: explicitly unassign it first. Deleting an unassigned
Zone soft-deletes its draft and retains immutable versions and target snapshots.
Unassignment changes the next complete target only. Editing a draft never updates
an assigned version implicitly, and no operation starts a stopped service.

Exports use the committed target JSONB snapshot outside a write transaction, pass it
through ConfigSpec encoding and decoding, and check normalized equality and semantic
digests. A failed export can be retried for the same revision. This verifies
PostgreSQL/export consistency, not a physical Worker's disk or runtime.

## Acceptance checks

Set the database URL to a dedicated, disposable test database; tests apply Ecto
migrations and use SQL Sandbox. Run from this application inside `devenv shell`:

```sh
mix test
mix compile --warnings-as-errors
mix format --check-formatted
```

Run shared fixture tests separately in the ConfigSpec application. `test/release_smoke.py`
requires a built production release and a **freshly migrated empty disposable DB**.
It starts/stops the actual release twice, asserts its dependency set, exercises
four-Worker allocation, and verifies restart/idempotency/historical export durability.
It intentionally fails on a populated database instead of deleting data.

```sh
python3 test/release_smoke.py /absolute/release/bin/yellow_dog_management
```

Future authenticated attachment, observation reports and remote delivery belong to
Phase 2. They must consume confirmed targets and leave this data ownership and
single ConfigSpec boundary intact.
