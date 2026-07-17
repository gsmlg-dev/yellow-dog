# Server Task 9A2 Report: Runtime Adapter And Config Applier

Date: 2026-07-17

## Status

DONE

## Implementation

- Added `YellowDog.ServerAgent.RuntimeAdapter` with exactly the approved
  `validate_config/1`, `install_config/2`, `activate_config/1`, and
  `restore_config/1` callbacks.
- Added serialized `YellowDog.ServerAgent.ConfigApplier` with the required
  `start_link/1`, `child_spec/1`, and `apply/2` boundary.
- Validates the strict option set, duplicate keys, concrete Server identity,
  profile, live ConfigStore/ConfigApplyStore references, and adapter module.
  The adapter defaults to the literal atom
  `:"Elixir.YellowDog.Server.Control"`.
- Calls ConfigApplyStore preflight before ConfigStore mutation. New and safe
  resumed candidates are staged idempotently and require exact equality
  between `ConfigStore.stage/2` and `ConfigStore.current/1`.
- Implements the approved checkpoint/callback order:
  `delivered -> before_validate -> before_install -> install ->
  before_activate -> activate -> applied`.
- Passes only the exact install options `version`, `digest`,
  `expected_revision`, `operation`, and `profile`, in that order, and validates
  returned revisions through `YellowDog.Sync.Digest`.
- Requires all four runtime callbacks dynamically before validation. Missing
  callbacks fail closed as a durable bounded validation failure.
- Sanitizes adapter errors, malformed returns, raises, throws, and exits into
  fixed phase-specific reasons without retaining raw payloads, paths, tokens,
  reasons, or stack traces.
- Implements no-known-good apply failure and known-good restore/reactivation
  rollback with truthful durable success/failure evidence.
- After every side-effect callback, a failed following transition is converted
  to durable `unknown`. If `unknown` cannot be persisted, ConfigApplier
  fail-stops with a stable internal reply.
- On init, inspects ConfigApplyStore and converts any still-exposed side-effect
  checkpoint to durable `unknown` before serving. Unknown, terminal, and pure
  checkpoints are preserved.
- Exact terminal/unknown duplicates replay only the ConfigApplyStore pending
  outbox. Publication acknowledgement/failure never invokes runtime work.
- ConfigApplier retains no apply evidence itself; GenServer ownership supplies
  serial exclusion for concurrent deliveries.
- A secondary atomic registration keyed by the resolved ConfigApplyStore PID
  now enforces one ConfigApplier owner independently of nil or differing public
  process names. Contending starts fail before serving, and termination releases
  the registration. The configured ConfigApplyStore name/reference remains
  unchanged for calls so a store restarted under the same name remains
  reachable; the resolved PID is retained separately only for ownership.
- Every ConfigApplyStore success is validated before snapshot dereference or
  public return. Compact validators prove target identity plus only the
  init/replay fields ConfigApplier consumes and the event-specific
  status/checkpoint/runtime contract. Three transition-specific checks cover
  only previous known-good, installed revision, and applied known-good
  coherence; the ConfigApplyStore persistence codec is not duplicated.
- Pending publications are accepted only as at most three exact-shape entries
  with contiguous positive sequences, canonical encoded `ConfigState`
  round-trips, and matching Server target identity. A malformed entry rejects
  the entire result without exposing encoded bytes.
- Validation is exception-safe inside the ConfigApplier process. A malformed
  post-callback transition follows the existing durable-unknown path, and a
  malformed unknown-transition success preserves the existing fail-stop
  behavior.

## Tests

Focused coverage includes:

- exact RuntimeAdapter callbacks and strict ConfigApplier options;
- literal production default and four-callback availability checks;
- exact callback order, payload, revision, and install options;
- validation, install, candidate activation, restore, and reactivation
  success/failure paths;
- adapter error payloads, malformed returns, raises, throws, and exits for
  pure and side-effect callbacks;
- first-apply install/activation failure without rollback;
- known-good rollback success, restore failure, and reactivation failure;
- exact terminal replay, conflict-before-stage, and safe pure resume;
- stage/current equality enforcement and concurrent call serialization;
- ConfigApplyStore PID ownership races across distinct public names, nil-name
  contention, and registration release on termination;
- named ConfigApplyStore restart through the retained configured reference;
- valid failed/unconfigured init and replay snapshots;
- malformed init, preflight replay, pre-side-effect, post-side-effect, and
  unknown-transition success shapes;
- publication capacity, sequence, exact-key, message-type, canonical-byte, and
  target-coherence rejection without partial disclosure;
- persistence failure before install;
- persistence failure after install, activation, restore, and reactivation;
- fail-stop when durable unknown cannot be established;
- init recovery, recovery persistence failure, and real-store restart from a
  side-effect checkpoint;
- outbox replay without adapter rerun.

## Verification

- TDD red:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test test/yellow_dog/server_agent/config_applier_test.exs'`
  - Initial implementation result: `22 tests, 22 failures` because
    RuntimeAdapter and ConfigApplier were absent.
  - Independent-review regression result: `28 tests, 5 failures`, reproducing
    both-owner startup, malformed replay/publication exposure, the
    before-install dereference crash, and malformed post-activation acceptance.
  - Named-store restart regression result: `30 tests, 1 failure`, reproducing
    the stale resolved-PID call reference after a same-name store restart.
- Focused tests:
  - Same focused command after implementation and expanded coverage.
  - Result: `31 tests, 0 failures`.
- Full Server-agent tests:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test'`
  - Result: `193 tests, 0 failures`.
- Warnings-as-errors compile:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix compile --warnings-as-errors --force'`
  - Result: exit 0, 12 files compiled, no warnings.
- Scoped format:
  - `devenv shell -- mix format --check-formatted <three modified owned Elixir files>`
  - Result: exit 0.
- Strict Credo:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix credo --strict'`
  - Result: 26 source files, 994 mods/funs, no issues.
- Dependency guard:
  - `mix deps.tree --only prod` reports only `yellow_dog_sync` as an umbrella
    dependency plus the existing Hex packages; there is no `yellow_dog`
    dependency.
- Xref guards:
  - ConfigApplier has no compile dependency edges.
  - Its full sibling-inclusive trace contains only Sync, ConfigStore, and
    ConfigApplyStore references.
- Forbidden guard:
  - No Server aliases, runtime Config/Store/ServiceManager calls, Concord, UDP,
    environment reads, or `:yellow_dog` dependency declarations occur in the
    production files.
- Dialyzer:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix dialyzer'`
    cannot bootstrap the umbrella PLT because sibling `yellow_dog_sync` does
    not define the `dialyzer` task. No analysis ran. Fixing sibling/root mix
    configuration is outside Task 9A2 ownership.

## Scope

Owned files:

- `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/runtime_adapter.ex`
- `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/config_applier.ex`
- `apps/yellow_dog_server_agent/test/support/config_applier_support.ex`
- `apps/yellow_dog_server_agent/test/yellow_dog/server_agent/config_applier_test.exs`
- `.superpowers/sdd/server-task-9a2-report.md`

Protected dirty console and root Mix files were left untouched and will not be
staged. ConfigApplyStore, ConfigStore, Supervisor, Client, Sync schemas,
runtime apps, releases, and mix files were not modified.

## Residual Concern

- Production remains intentionally fail-closed with
  `runtime adapter unavailable` until the runtime owner supplies all four
  callbacks through `YellowDog.Server.Control`.
