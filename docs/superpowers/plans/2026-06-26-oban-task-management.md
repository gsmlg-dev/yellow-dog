# Concord Task Management Implementation Plan

**Goal:** Add the PRD MVP for YellowDog data synchronization tasks without introducing a separate SQL-backed job database. Task jobs and schedule reservations are persisted through `YellowDog.Store`, which uses Concord in clustered deployments and the existing ETS backend in tests/single-node runs.

**Architecture:** Add a new umbrella app, `yellow_dog_tasks`, that owns task configuration, scheduling, job state transitions, worker modules, region-data storage, and task status APIs. Keep console UI in `yellow_dog_console`; the UI calls `YellowDog.Tasks` to enqueue jobs and read job history. Existing GeoIP and OUI download modules expose small test seams so worker tests can prove atomic failure behavior without external HTTP.

## Scope

- `apps/yellow_dog_tasks`
- Task config additions in `apps/yellow_dog_config` and default TOML files
- Task console pages under `apps/yellow_dog_console`
- Store key helpers in `apps/yellow_dog_store`
- Focused tests for the touched apps

## Design

1. Add `YellowDog.Tasks.Job` as the persisted job record.
2. Add `YellowDog.Tasks.Store` as the only persistence boundary for task jobs and scheduler reservations.
3. Use `YellowDog.Store.backend_put/get/delete/prefix_scan/put_if` and `YellowDog.Store.Key` helpers. Do not call Concord directly from `yellow_dog_tasks`.
4. Add `YellowDog.Tasks.Runner` to enqueue jobs, reserve due schedules per minute, and execute jobs through a `Task.Supervisor`.
5. Use compare-and-set state transitions so only one runner can move a job from `available` to `executing`.
6. Keep workers as plain modules exposing `perform(%YellowDog.Tasks.Job{})`.
7. Parse the fixed five-field cron expressions locally in `YellowDog.Tasks.Cron`; do not add a separate scheduler dependency for cron parsing.
8. Surface status through `YellowDog.Tasks.TaskStatus`, backed by recent persisted jobs.

## Verification

- `mix format`
- `mix test` for `apps/yellow_dog_tasks`
- `mix test test/yellow_dog/store/key_test.exs` for `apps/yellow_dog_store`
- `mix test test/yellow_dog/console/live/tasks_live_test.exs` for `apps/yellow_dog_console`
- `mix test test/yellow_dog/config/schema_test.exs` for `apps/yellow_dog_config`
- `mix compile --warnings-as-errors`
- `nix build .#yellowdogdns --no-link`

## Status

- [x] Created `yellow_dog_tasks`
- [x] Added task config/defaults
- [x] Added data sync task registry and workers
- [x] Added Concord-backed job ledger through `YellowDog.Store`
- [x] Added scheduled runner and manual enqueue path
- [x] Added console task list/history pages
- [x] Added focused unit and LiveView tests
- [ ] Run final scoped verification
