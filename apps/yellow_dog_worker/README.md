# Yellow Dog Worker (Phase 1)

An independent Linux service host. It reads the shared ConfigSpec WorkerPlan from
local TOML, runs authoritative DNS, and recovers from its own committed snapshots.
It has no PostgreSQL, Management URL, credentials, enrollment, Agent, or management
connection. `YellowDog.Worker.submit_plan/2` is the sole internal future-Agent
attachment point; it uses exactly the same path as local reload.

## Build and run

The shared-file owner must first adopt `docs/phase1/config-spec.patch`. This Track B
change uses that existing C0 implementation and does not change its format. For an
isolated build before shared integration, from the repository root:

```sh
docs/phase1/prepare-worker-validation.sh /tmp/yellow-dog-track-b-validation
devenv shell -- bash -c 'cd /tmp/yellow-dog-track-b-validation/apps/yellow_dog_worker && mix deps.get && MIX_ENV=prod mix release yellow_dog_worker --overwrite'
```

Copy `examples/bootstrap.toml` and `examples/plan.toml` to a local configuration
directory. Adjust `worker_id` in both files and the DNS listen address/port in the
plan. The sample binds loopback port 1053. Bootstrap paths are relative to the
bootstrap file. Bootstrap has exactly three required fields: `worker_id`, `source`,
and `data_dir`. Its identity and machine-local paths never come from a managed plan.

```sh
YELLOW_DOG_WORKER_BOOTSTRAP=/etc/yellow-dog/bootstrap.toml \
  /tmp/yellow-dog-track-b-validation/_build/prod/rel/yellow_dog_worker/bin/yellow_dog_worker start
```

Linux runtime tools `flock`, POSIX `sh`, `cat`, and GNU `sync` must be on PATH.
The release contains the Erlang runtime. DNS ports below 1024 need the appropriate
OS permission; use an unprivileged port for validation. The source and data directory
must be owned by the trusted local operator; symlink paths are rejected. Do not use
a network filesystem: this implementation relies on local Linux flock/rename/syncfs
semantics. It does not claim safety against a malicious writer with the same UID.

## Local control and precedence

In the release's remote console (`bin/yellow_dog_worker remote`) or with its local
`rpc` command:

```elixir
YellowDog.Worker.status()
YellowDog.Worker.check()
YellowDog.Worker.reload()
```

For example, `bin/yellow_dog_worker rpc 'IO.inspect(YellowDog.Worker.reload())'`.
Release RPC uses normal Erlang distribution and its cookie; it is local operator
control, not a Management Agent. Standard release node/cookie settings must match
between `start` and `rpc`. Use `RELEASE_DISTRIBUTION=none` when RPC is not needed.

First boot with no committed snapshot reads the source. Invalid first-boot source
leaves Worker alive and explicitly not ready, with the validation error available
in status. A missing/invalid bootstrap or unavailable data-directory lock fails boot.

Once a plan is committed, restart always restores that snapshot, even if the source
is missing, invalid, or contains uncommitted changes. Edit source and explicitly
invoke `reload()` to change the desired state. There is no file watcher or implicit
source overwrite on restart. To stop/start DNS, change its `desired_state` to
`stopped`/`running` and reload. There are no memory-only lifecycle overrides.
Updating a stopped service persists its data without creating listeners. Removing
an instance from the complete plan stops it. Required explicit empty service and
resource arrays are valid; missing arrays are invalid.

A reload validates the entire plan and target identity, stages an immutable snapshot,
serializes each service's change, and commits one pointer only after all applications
succeed. Failures restore the recoverable committed target and report the rejection,
attempted per-service outcomes and rollback outcome. Cross-service cutover is not
simultaneous; each DNS query sees one complete in-memory zone snapshot. DNS data
updates with an unchanged binding keep the listener process running. Resource
versions and DNS SOA serials are explicit input fields, separate from plan revision.

Equivalent semantic reloads retain the existing committed revision, snapshot and
healthy service PID. A missing runtime is repaired through the same controller;
missing/corrupt persisted data can be reinstalled on explicit reload. Status has
separate desired, prepared, persisted, active, readiness and error fields; `check()`
returns structured runtime/content/disk differences and does not execute repair.
A rejected reload can coexist with a ready last-valid service; inspect `error`.

## Supported configuration

Plans use the one shared C0 schema described in
`docs/phase1/shared-baseline/README.md`. The checked-in example is the shared complete
SOA/NS/A fixture. Resources are self-contained in the plan's TOML; external resource
file references are not defined by C0 and are rejected, rather than interpreted as
an alternate format. Service resource references select IDs in that complete plan.

Only allowlisted `dns` instances and `dns_zone` resources are executable. IPv4
listeners, IN SOA/NS/A data, authoritative UDP/TCP queries, negative replies and
UDP truncation are supported. Recursion, zone transfers, DNSSEC, non-apex NS
referrals/delegations and other record data are outside this adapter's supported
surface. Unsupported configuration fails explicitly. Queries outside loaded zones
are refused. DNS answers use loaded memory and never read TOML per query.

C0 bounds a plan to 1 MiB, 64 services, 256 resources and 1,024 records per zone;
IDs and domain/record fields have additional shared bounds. Input digests are
recomputed. No configuration string is converted to an executable module or atom.

## Persistence and recovery

`data_dir` is owned by one LocalStore. A kernel flock held by a child process is
released when its owning process/VM dies; a second Worker is refused. The snapshots
are complete generated TOML, addressed by SHA-256 of canonical encoded bytes. These
storage hashes are distinct from shared semantic resource/plan digests.

The store writes a uniquely named temporary file, checks file sync and close,
reads/validates the generated TOML, renames it to the immutable snapshot name, and
checks directory/filesystem synchronization with GNU `sync -f` (Linux syncfs).
Only then does it write/sync/read back a temporary commit pointer and atomically
replace `current`, followed by synchronization. The pointer names both active and
previous snapshots. Prepared but uncommitted files never become startup state.
A post-rename synchronization error attempts a synchronized pointer rollback;
failure of rollback is explicitly `commit_uncertain`, never success.

Recovery verifies snapshot bytes and parses the full shared plan. If the active
snapshot is damaged and the previous one is valid, status reports recovery on the
previous version. Corrupt commit records fail explicitly. No garbage collection is
implemented: active, previous and staged snapshots are all retained. Operators must
monitor disk usage. The fault tests exercise write/permission/sync failures and
process interruption; they do not simulate every filesystem or physical power loss.

## Verification

```sh
devenv shell -- bash -c 'cd /tmp/yellow-dog-track-b-validation/apps/yellow_dog_worker && mix test && MIX_ENV=test mix compile --warnings-as-errors && mix format --check-formatted'
python3 apps/yellow_dog_worker/test/release_smoke.py /tmp/yellow-dog-track-b-validation/_build/prod/rel/yellow_dog_worker/bin/yellow_dog_worker
```

The release smoke uses real sockets and independent OS restarts, including SIGKILL.
It unsets Management/database environment settings, checks release dependencies,
serves SOA/NS/A on UDP and TCP, reloads during queries, verifies no-op file/PID
stability, rejects a second directory owner, and proves stopped-state persistence
and later explicit start with updated data. See `docs/phase1/track-b-report.md` for
actual results and outstanding shared integration.
