# Server Task 7B Report: Config Manager Unsupported Boundary

## Status

Complete. This report supersedes the durable Manager claims in the Task 7B
report committed by `b1dea263`.

The independent review established that the current runtime and fixed Settings
transport cannot support the proposed durable mutation lifecycle safely. Task
7B now provides only a small, console-independent
`YellowDog.Config.Manager` facade that validates a bounded service identifier
and operation-level top-level types before returning stable typed errors.

This revision also resolves the two remaining review findings. It supersedes
the prior claim that Manager independently validates Settings entry grammar,
entry values, nesting depth, entry counts, text sizes, or rollback digest
semantics.

## Implemented Boundary

`YellowDog.Config.Manager` exposes:

- `effective/1`
- `source/1`
- `revision/1`
- `validation/1`
- `update/2`
- `apply/1`
- `reload/1`
- `rollback/2`

Every operation with a valid bounded service identifier and the expected
top-level argument type returns `{:error, :unsupported}`:

- `update/2` accepts any list as an opaque entries container;
- `rollback/2` accepts any binary as an opaque revision reference;
- the remaining operations require only a valid service identifier.

Malformed or unbounded service identifiers and wrong top-level argument types
return `{:error, :invalid}`. Manager does not inspect, classify, count, or
traverse entries, nested values, or revision-reference contents. Its payload
path therefore does not allocate validation state proportional to payload
size.

The Manager is a pure module. Calls perform no filesystem, Config Agent,
runtime adapter, history, telemetry, process, or secret access or mutation.
They return no paths, raw TOML, configuration values, local counters, runtime
references, or raw errors.

## Settings Adapter Ownership

The later Settings adapter is the sole owner of the fixed Sync entry grammar
and its aggregate 1,048,576-byte request bound. It must fully validate those
requirements before invoking Manager. Manager intentionally does not duplicate
that grammar or apply independent semantic, per-entry, recursive, depth, or
aggregate-size rules.

Consequently, payloads that are fixed-valid, including empty setting text, are
not rejected by Manager. Payloads that are fixed-invalid because of semantic
values also remain opaque and receive `{:error, :unsupported}` when their
top-level shape is valid. The adapter remains responsible for classifying
those payloads as invalid before they reach this boundary.

## Removed And Restored

The rejected implementation from `b1dea263` was removed:

- deleted `YellowDog.Config.Manager.Storage`;
- deleted immutable history and target-file writes;
- deleted activation, compensation, rollback, and path-lock logic;
- deleted Config Agent reads and replacement;
- deleted Manager application supervision;
- removed the added `:crypto` extra application;
- restored `YellowDog.Config.Writer` exactly to its pre-Task 7B behavior;
- removed the Task 7B Writer test for the reverted encode-only API.

No Server adapter, Identity, console, root Mix, runtime config, protocol,
Concord, Mnesia, or protected file was modified.

## Deferred Lifecycle Requirements

A future durable Settings owner requires a separate cross-cutting design and
must not be inferred from this facade. At minimum, that design must provide:

1. A revised Settings entry schema that can losslessly represent ordinary
   current configuration, including ports, paths, nested tables, and arrays.
2. One durable source of truth for immutable positive versions, digests,
   snapshots, lifecycle state, and bounded failure evidence.
3. Startup recovery for every crash window across history reservation, target
   installation, Config Agent replacement, activation, and lifecycle commit.
4. Durable path ownership and serialization across processes and nodes.
5. Exact-byte target restoration with proven atomic write, sync, close,
   rename, directory-sync, and reread behavior on supported platforms.
6. A recoverable protocol for coordinating installed bytes and Config Agent
   state without treating the restart-local Agent counter as a revision.
7. A concrete activation and restore owner for each supported service. A file
   write or Agent replacement alone must never be reported as applied.
8. Idempotent activation and rollback semantics that remain correct after
   process or node restart.
9. A failure model that can distinguish validation, delivery, apply, and
   rollback failure without exposing paths, secrets, raw TOML, or exceptions.
10. End-to-end tests that inject crashes, not only returned errors, at every
    persistence and runtime transition.

Until those requirements have an accepted design and implementation, all
Settings reads and mutations remain explicitly unsupported.

## Verification

- Focused Manager:
  `cd apps/yellow_dog_config && mix test test/yellow_dog/config/manager_test.exs`
  - 10 tests, 0 failures.
  - Covers fixed-valid empty text, opaque fixed-invalid semantic values, a
    deeply nested value, a prebuilt 250,000-entry list with a bounded-reduction
    call assertion, top-level type rejection, and zero side effects.
- Full Config app: `cd apps/yellow_dog_config && mix test`
  - 92 tests, 0 failures.
- Compile:
  `cd apps/yellow_dog_config && mix compile --warnings-as-errors --force`
  - 8 files compiled, no warnings.
- Format: root `mix format --check-formatted` over `yellow_dog_config` Mix,
  library, and test files.
  - Passed.
- Credo: `cd apps/yellow_dog_config && mix credo --strict`
  - 14 files checked, no issues.

## Concerns

- The later Settings adapter must enforce the exact fixed Sync grammar and
  aggregate byte bound before calling Manager, preserve `:invalid` versus
  `:unsupported`, and not bypass this owner boundary with direct Config Agent,
  Writer, filesystem, console, or runtime calls.
- Unsupported reads are intentional: the fixed Settings grammar cannot
  currently provide a lossless, safe effective/source/revision/validation
  projection.
