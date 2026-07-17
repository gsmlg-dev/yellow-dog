# Server Task 7D Report: Settings Server Control Adapter

## Scope

Implemented only the Settings Server control slice:

- `apps/yellow_dog/lib/yellow_dog/server/control/settings.ex`
- `apps/yellow_dog/test/yellow_dog/server/control/settings_control_test.exs`
- `apps/yellow_dog/test/support/settings_control_fake.ex`

No Dispatcher, Config Manager, Identity, console, protocol, root Mix, or
protected user files were changed.

## Implementation

`YellowDog.Server.Control.Settings` is a thin fixed-schema facade over
`YellowDog.Config.Manager`.

- It supports the fixed operations `effective.get`, `source.get`,
  `revision.get`, `validation.get`, `update`, `apply`, `reload`, and
  `rollback`.
- Every `dispatch/2` path obtains the fixed Server operation and validates its
  exact Sync payload before calling the matching Manager function.
- The production Manager dependency is fixed to `YellowDog.Config.Manager`.
  In test only, one validated `manager:` module override is permitted. Unknown,
  duplicate, non-module, or nil configuration is rejected as a sanitized
  internal error.
- Manager `:invalid`, `:not_found`, `:conflict`, `:unsupported`,
  `:apply_failed`, and `:rollback_failed` responses are converted to fixed
  `YellowDog.Sync.Error` values with empty details. Unexpected returns,
  raises, throws, and exits are reduced to sanitized fixed errors. An absent
  Manager owner is `:not_found`.
- `current/2` validates every supplied fixed payload and then returns typed
  `:unsupported`. It never asks Manager for a synthetic current resource, so
  Dispatcher cannot construct a stale revision or applied-state result for any
  unsupported Settings mutation.
- The adapter does not read files, TOML, Config Agent state, Writer state, or
  runtime/service state. It forwards successful Manager maps unchanged so the
  Dispatcher remains responsible for Sync result normalization and recursive
  Settings secret redaction.

With the current pure Manager, every well-formed production operation returns
typed unsupported after the adapter's exact Sync validation. No config state,
revision, source, diagnostics, reload, apply, or rollback result is fabricated.

## Test Coverage

The dedicated non-async Settings suite covers:

- every read and mutation mapping to the real Manager call table;
- malformed fixed inputs before Manager access;
- real Dispatcher read paths and all four well-formed mutation envelopes,
  including `settings.update` with its required `config_version`, returning
  `unsupported` through `current/2` without Manager calls;
- stale expected revisions tested separately for each unsupported mutation,
  returning `unsupported` rather than synthetic conflicts;
- bounded Settings entries and bounded validation diagnostics;
- malformed Manager success values, unknown error reasons, arbitrary return
  terms, errors, exceptions, throws, and exits all falling back to sanitized
  fixed adapter errors, including malformed read results through the real
  Dispatcher path;
- a loaded and exported Manager module whose backing owner process is stopped,
  proving the resulting `:noproc` exit is sanitized to fixed `not_found`, plus
  invalid override sanitization to fixed `internal`;
- real Dispatcher rejection of an over-bound Manager effective-settings
  `entries` collection, with direct Sync result-schema validation coverage;
- recursive effective-settings secret redaction through real Dispatcher result
  normalization;
- a source-level guard against direct Config Agent, Writer, filesystem, TOML,
  system, or ServiceManager access.

The test was written before `settings.ex`. The initial red run failed because
the Settings module was absent. After the minimal adapter implementation and
the independent-review coverage additions, the focused suite passed with `14
tests, 0 failures`.

## Verification

The fresh focused test command passed exactly as follows:

```text
devenv shell -- bash -lc "cd apps/yellow_dog && mix test test/yellow_dog/server/control/settings_control_test.exs --seed 0"
14 tests, 0 failures
```

The requested full app suite was rerun but could not reach ExUnit because an
unrelated concurrent edit in `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/storage.ex`
does not compile (`validate_write_opts/1` is undefined at line 74):

```text
devenv shell -- bash -lc "cd apps/yellow_dog && mix test --seed 0"
Compilation error in YellowDog.ServerAgent.Storage; no test count produced.
```

The owned-surface verification passed:

```text
devenv shell -- bash -lc "cd apps/yellow_dog && mix compile --warnings-as-errors"
Generated yellow_dog app

devenv shell -- bash -lc "cd apps/yellow_dog && mix credo --strict lib/yellow_dog/server/control/settings.ex test/yellow_dog/server/control/settings_control_test.exs test/support/settings_control_fake.ex"
63 mods/funs, found no issues.

devenv shell -- bash -lc "cd apps/yellow_dog && mix format --check-formatted test/yellow_dog/server/control/settings_control_test.exs test/support/settings_control_fake.ex"
exit 0

git diff --check
exit 0
```

## Self-Review

- No shared Dispatcher implementation or test file was changed.
- No unsafe caller-selected module/function routing was introduced.
- No Config Agent, Writer, filesystem, TOML, runtime, protocol, UDP, Mnesia,
  Concord, migration, or console access was added.
- Full `apps/yellow_dog` test verification remains blocked by the unrelated
  concurrent ServerAgent compile error described above; no workaround or edit
  was made outside this Task 7D ownership.
