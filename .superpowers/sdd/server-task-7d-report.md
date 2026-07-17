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
- real Dispatcher read paths and mutation `current/2` paths, including stale
  expected revisions returning `unsupported` rather than synthetic conflicts;
- bounded Settings entries and bounded validation diagnostics;
- malformed Manager success values, unknown error reasons, arbitrary return
  terms, errors, exceptions, throws, and exits all falling back to sanitized
  fixed adapter errors;
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
the independent-review coverage additions, the focused suite passed with `12
tests, 0 failures`.

## Verification

Passed:

```text
devenv shell -- bash -lc "cd apps/yellow_dog && mix compile --warnings-as-errors"
devenv shell -- bash -lc "cd apps/yellow_dog && mix credo --strict lib/yellow_dog/server/control/settings.ex test/yellow_dog/server/control/settings_control_test.exs test/support/settings_control_fake.ex"
devenv shell -- bash -lc "cd apps/yellow_dog && mix format --check-formatted lib/yellow_dog/server/control/settings.ex test/support/settings_control_fake.ex test/yellow_dog/server/control/settings_control_test.exs"
devenv shell -- bash -lc "git diff --check"
```

The final focused test command passed exactly as follows:

```text
devenv shell -- bash -lc "cd apps/yellow_dog && mix test test/yellow_dog/server/control/settings_control_test.exs"
12 tests, 0 failures
```

The full app suite also passed exactly as follows:

```text
devenv shell -- bash -lc "cd apps/yellow_dog && mix test"
404 tests, 0 failures
```

## Self-Review

- No shared Dispatcher implementation or test file was changed.
- No unsafe caller-selected module/function routing was introduced.
- No Config Agent, Writer, filesystem, TOML, runtime, protocol, UDP, Mnesia,
  Concord, migration, or console access was added.
