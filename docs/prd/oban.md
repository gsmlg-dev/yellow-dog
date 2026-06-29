# PRD: Oban Task Management Module for YellowDog Data Synchronization

## 1. Summary

Add a new **Oban Task Management** module to YellowDog for scheduling, executing, monitoring, and manually triggering recurring data synchronization jobs.

The first release will support scheduled synchronization for:

1. **Region data**
2. **IP geolocation database**
3. **MAC / OUI manufacturer database**

The module should integrate with the existing YellowDog Console, reuse the current GeoIP and MAC database functionality, and provide a unified task-management UI for operators.

YellowDog already has manual system pages for IP database and MAC database management under the console router, including `/system/ip-database` and `/system/mac-database`. The IP database page currently supports manual download/update of DB-IP Lite MMDB files, and the MAC database page supports manual download/reload of the Wireshark `manuf.txt` OUI database. ([GitHub][1])

## 2. Background and Repository Findings

YellowDog is an umbrella Elixir project with multiple applications, including `geo_ip_db`, `yellow_dog_console`, `yellow_dog_fingerprint`, DNS, DHCPv4, DHCPv6, mDNS, netboot, identity, telemetry, and store components. The README identifies `geo_ip_db` as an infrastructure library and lists the web console as one of the core applications. ([GitHub][2])

The `geo_ip_db` app already provides an IP geolocation database abstraction using MMDB format. It supports DB-IP.com and MaxMind-style databases, exposes APIs such as `lookup/2`, `country/2`, `city/2`, `coordinates/2`, `database_info/1`, and `load_database/2`, and includes default DB-IP city and country database filenames. ([GitHub][3])

The `GeoIpDb.Database` GenServer manages MMDB loading, file paths, metadata, list operations, and download/reload behavior. The download implementation builds current-month DB-IP Lite URLs, downloads compressed database files, decompresses them, saves them to disk, and hot-loads the updated database. ([GitHub][4])

The MAC/OUI database is already implemented in `YellowDog.Fingerprint.OuiDatabase`. It is runtime-reloadable, uses ETS for fast reads, starts from the compiled `gsmlg_mac` table as a baseline, and can download the latest Wireshark `manuf.txt` file and hot-reload the lookup table without restarting the application. ([GitHub][5])

The console application currently supervises `GeoIpDb.Database`, Phoenix PubSub, telemetry, settings, logging, authentication rate limiting, NetMan registry, and the Phoenix endpoint. This is the natural place to add task UI and Oban supervision, or to supervise a new task app alongside the console. ([GitHub][6])

The repository already references `YellowDog.Console.Repo` in configuration, but the inspected console app does not appear to define a production-ready Repo module or database adapter configuration. Oban requires an Ecto repo and a supported database engine, so Repo/database setup is part of this PRD rather than an optional implementation detail. ([GitHub][7])

## 3. Problem Statement

YellowDog currently supports manual updating of the IP and MAC databases, but there is no unified scheduled task system for data synchronization.

This creates several operational gaps:

Operators must remember to update databases manually.

There is no central place to see the last sync time, next scheduled sync, job status, retry count, or failure reason.

IP, MAC, and region data synchronization are not managed through one consistent workflow.

Failed downloads or reloads are not represented as durable jobs with retry history.

There is no standard mechanism for deduplication, backoff, scheduling, or operational observability.

## 4. Goals

The goal is to add an Oban-backed task-management module that allows YellowDog to automatically keep external data sources current and observable.

The module must:

Provide scheduled sync jobs for region data, IP database, and MAC database.

Allow an administrator to manually trigger each sync from the web console.

Show last run, next run, current status, success/failure result, and recent job history.

Prevent duplicate concurrent syncs of the same dataset.

Retry transient failures safely.

Preserve the previously working dataset when a sync fails.

Integrate with the existing IP and MAC database modules instead of replacing them.

Support configuration through YellowDog’s runtime configuration model and data directory structure.

Expose telemetry/logging so task health can be monitored.

## 5. Non-Goals

This release will not:

Replace the existing GeoIP lookup API.

Replace the existing MAC/OUI lookup implementation.

Require Oban Pro.

Add arbitrary user-defined task execution.

Implement a paid MaxMind license workflow unless explicitly configured by the operator.

Guarantee real-time updates from upstream providers; sync cadence will be scheduled.

Replace the existing `/system/ip-database` and `/system/mac-database` pages immediately. Those pages should be integrated or linked from the new task module.

## 6. Users and Personas

### 6.1 System Administrator

Runs YellowDog in a home lab, office, ISP, or network appliance environment.

Needs databases to update automatically.

Needs simple controls: enable, disable, run now, view status.

### 6.2 Network Operator

Uses GeoIP, device identity, DHCP, DNS, and MAC vendor lookup features.

Needs confidence that lookup data is fresh and that failed updates are visible.

### 6.3 Developer / Maintainer

Needs a clean background-job architecture that fits the Elixir umbrella application.

Needs deterministic tests, safe retry behavior, and clear extension points for new task types.

## 7. Proposed Product Scope

Add a new module named:

`YellowDog.Tasks`

or, if implemented as a separate umbrella app:

`yellow_dog_tasks`

Recommended first implementation:

Use a new umbrella app called `yellow_dog_tasks` for task domain logic and workers, while exposing UI in `yellow_dog_console`.

This separation keeps scheduling and worker logic reusable outside the Phoenix console while allowing the web console to manage and observe tasks.

## 8. Functional Requirements

## 8.1 Oban Infrastructure

### Requirement

Add Oban to YellowDog and configure it with a durable Ecto repository.

Oban jobs are Ecto schemas stored in a database and inserted through changesets, and Oban requires an Ecto repo configured for a supported database engine. Current Oban documentation lists PostgreSQL, MySQL, and SQLite support, with separate engines/configuration examples. ([Hexdocs][8])

### Recommended Database Decision

Use **SQLite as the default embedded task database** for YellowDog.

Rationale:

YellowDog appears to be appliance/file-system oriented.

Runtime data already uses `YELLOW_DOG_DATA_DIR`, with production data intended to live under a data directory such as `/data/yellowdog`. ([GitHub][9])

The inspected production config does not appear to define a production Postgres database.

Requiring Postgres would add operational complexity for users running YellowDog as a network service appliance.

Oban supports a Lite engine for SQLite according to the current installation examples. ([Hexdocs][10])

Default database path:

```text
${YELLOW_DOG_DATA_DIR}/tasks/yellow_dog_tasks.db
```

Future option:

Allow PostgreSQL through configuration for clustered deployments.

### Implementation Requirements

Add dependencies:

```elixir
{:oban, "~> 2.23"},
{:ecto_sql, "~> 3.12"},
{:ecto_sqlite3, "~> 0.21"}
```

Exact versions should be aligned with the project lockfile during implementation.

Add Repo module:

```elixir
defmodule YellowDog.Tasks.Repo do
  use Ecto.Repo,
    otp_app: :yellow_dog_tasks,
    adapter: Ecto.Adapters.SQLite3
end
```

Add Oban migration:

```elixir
defmodule YellowDog.Tasks.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 1)
  end
end
```

Oban’s installation guide requires adding a jobs table through `Oban.Migration` and supervising both the Repo and Oban process. ([Hexdocs][10])

Add supervision:

```elixir
children = [
  YellowDog.Tasks.Repo,
  {Oban, Application.fetch_env!(:yellow_dog_tasks, Oban)}
]
```

Configure queue:

```elixir
queues: [
  data_sync: 1
]
```

`data_sync` should have concurrency `1` in the default configuration to prevent multiple sync jobs from downloading and hot-reloading shared files at the same time.

## 8.2 Oban Scheduling

### Requirement

Use Oban Cron for recurring sync jobs.

Oban Cron periodically enqueues jobs using cron expressions. In open-source Oban, cron configuration is static at boot; dynamic runtime cron management across a cluster requires Oban Pro DynamicCron. ([Hexdocs][11])

### Default Schedules

| Task                     | Default Schedule | Rationale                                             |
| ------------------------ | ---------------: | ----------------------------------------------------- |
| Region data sync         |    `0 2 * * SUN` | Weekly refresh unless source requires monthly cadence |
| IP country database sync |      `0 3 2 * *` | Monthly DB-IP country database refresh                |
| IP city database sync    |     `30 3 2 * *` | Monthly DB-IP city database refresh                   |
| MAC/OUI database sync    |    `0 4 * * SUN` | Weekly Wireshark manufacturer database refresh        |

Default timezone:

```text
Etc/UTC
```

Admin-configurable timezone should be supported. Oban Cron supports a timezone option, with UTC as the default. ([Hexdocs][11])

### Example Oban Config

```elixir
config :yellow_dog_tasks, Oban,
  engine: Oban.Engines.Lite,
  repo: YellowDog.Tasks.Repo,
  queues: [data_sync: 1],
  plugins: [
    {Oban.Plugins.Cron,
     timezone: "Etc/UTC",
     crontab: [
       {"0 2 * * SUN", YellowDog.Tasks.Workers.SyncRegionDataWorker,
        queue: :data_sync, tags: ["sync", "region"]},

       {"0 3 2 * *", YellowDog.Tasks.Workers.SyncIpDatabaseWorker,
        args: %{type: "country"}, queue: :data_sync, tags: ["sync", "ip", "country"]},

       {"30 3 2 * *", YellowDog.Tasks.Workers.SyncIpDatabaseWorker,
        args: %{type: "city"}, queue: :data_sync, tags: ["sync", "ip", "city"]},

       {"0 4 * * SUN", YellowDog.Tasks.Workers.SyncMacDatabaseWorker,
        queue: :data_sync, tags: ["sync", "mac"]}
     ]}
  ]
```

## 8.3 Task Types

## 8.3.1 Region Data Sync

### Purpose

Synchronize normalized region metadata used by YellowDog UI and future policy/identity features.

### Initial Data Model

Region data should support at least:

Country code

Country name

Subdivision / region code

Subdivision / region name

Optional city metadata

Source name

Source version or generated timestamp

Last sync timestamp

Record count

### Proposed Storage

Store normalized region data under:

```text
${YELLOW_DOG_DATA_DIR}/region/regions.json
${YELLOW_DOG_DATA_DIR}/region/metadata.json
```

Load into ETS for fast runtime reads if needed.

### Proposed API

```elixir
YellowDog.RegionData.list_countries()
YellowDog.RegionData.list_regions(country_code)
YellowDog.RegionData.lookup(country_code, region_code)
YellowDog.RegionData.info()
YellowDog.RegionData.reload()
YellowDog.RegionData.sync()
```

### Open Product Decision

The definitive upstream source must be selected before implementation.

Candidate sources:

ISO 3166-1 / ISO 3166-2 compatible dataset

GeoNames dump

MaxMind GeoLite metadata

DB-IP region/city-derived metadata

Recommendation:

Use a provider behavior so the source can change without changing Oban workers.

```elixir
defmodule YellowDog.RegionData.Provider do
  @callback download(keyword()) :: {:ok, binary(), map()} | {:error, term()}
  @callback normalize(binary()) :: {:ok, [map()]} | {:error, term()}
end
```

## 8.3.2 IP Database Sync

### Purpose

Automatically update IP geolocation MMDB databases.

YellowDog already has `GeoIpDb.Database.download(type)`, `GeoIpDb.Database.load(type, path)`, metadata access, file info, and list operations. The current download code uses DB-IP Lite URLs and hot-loads downloaded MMDB files. ([GitHub][4])

### Supported Types

```text
country
city
```

### Worker

```elixir
YellowDog.Tasks.Workers.SyncIpDatabaseWorker
```

### Job Args

```elixir
%{
  "type" => "country" | "city",
  "force" => boolean()
}
```

### Worker Behavior

Validate `type`.

Acquire task lock or rely on `data_sync` queue concurrency.

Download database to a temporary file.

Validate downloaded file:

file exists

file size above minimum threshold

MMDB parser can open it

metadata is readable

Atomically replace existing database.

Reload database through `GeoIpDb.Database`.

Emit success/failure telemetry.

Return `:ok` only after the new database is loaded.

### Failure Behavior

If download, decompression, validation, or reload fails:

Keep previous database file.

Keep previous loaded ETS/database state.

Mark Oban job as failed.

Show failure reason in task UI.

Allow retry.

## 8.3.3 MAC/OUI Database Sync

### Purpose

Automatically update MAC vendor / OUI manufacturer data.

YellowDog already has a runtime-reloadable OUI database. It uses ETS for reads, can start with compiled `gsmlg_mac` data, downloads Wireshark `manuf.txt`, and hot-reloads without restart. ([GitHub][12])

### Worker

```elixir
YellowDog.Tasks.Workers.SyncMacDatabaseWorker
```

### Job Args

```elixir
%{
  "force" => boolean()
}
```

### Worker Behavior

Ensure `YellowDog.Fingerprint.OuiDatabase` is running.

Download latest `manuf.txt`.

Validate file:

file exists

file size above minimum threshold

parsing returns non-zero entries

required prefixes are parseable

Atomically replace previous `manuf.txt`.

Reload OUI database.

Emit success/failure telemetry.

### Failure Behavior

If download or parse fails:

Keep previous OUI database.

Keep compiled fallback available.

Mark job failed.

Surface error in UI.

## 8.4 Manual Task Execution

Admins must be able to run each task manually from the console.

Required actions:

Run region sync now

Run IP country sync now

Run IP city sync now

Run MAC/OUI sync now

Retry failed job

Cancel scheduled or executing job where safe

Manual runs should enqueue Oban jobs instead of executing long-running downloads directly in LiveView processes.

Oban supports job options such as queue, scheduled time, tags, worker, and uniqueness, which should be used for consistent manual and scheduled execution. ([Hexdocs][8])

### Example Manual Enqueue

```elixir
%{"type" => "city", "force" => true}
|> YellowDog.Tasks.Workers.SyncIpDatabaseWorker.new(
  queue: :data_sync,
  tags: ["manual", "sync", "ip", "city"],
  unique: [
    period: 3600,
    fields: [:worker, :queue, :args],
    states: [:available, :scheduled, :executing, :retryable]
  ]
)
|> Oban.insert()
```

Oban uniqueness prevents duplicate enqueues at insertion time. It should be combined with queue concurrency because uniqueness does not replace runtime concurrency control. ([Hexdocs][13])

## 8.5 Task Management UI

Add a new console page:

```text
/system/tasks
```

Optional detail pages:

```text
/system/tasks/region
/system/tasks/ip
/system/tasks/mac
```

### Page: Task Overview

Show cards for:

Region Data

IP Country Database

IP City Database

MAC/OUI Database

Each card must display:

Task name

Enabled / disabled

Current status

Last success time

Last failure time

Next scheduled run

Schedule expression

Source

Current data version or metadata

Record count where available

Last job ID

Last error summary

Primary action: Run Now

Secondary actions: View History, Edit Schedule, Disable/Enable

### Page: Task History

Show recent Oban jobs for data sync workers.

Columns:

Job ID

Task type

Queue

State

Attempt

Max attempts

Inserted at

Scheduled at

Started at

Completed / discarded at

Duration

Tags

Error summary

Actions:

Retry

Cancel

View details

### Integration with Existing Pages

The current `/system/ip-database` page should show related task status and link to the IP sync task.

The current `/system/mac-database` page should show related task status and link to the MAC sync task.

Existing manual “Download” behavior should be changed to enqueue an Oban job rather than running download work directly from the LiveView.

## 8.6 Configuration

Add task configuration to YellowDog TOML config.

Example:

```toml
[tasks]
enabled = true
timezone = "Etc/UTC"
database_path = "tasks/yellow_dog_tasks.db"

[tasks.sync.region]
enabled = true
cron = "0 2 * * SUN"
max_attempts = 3

[tasks.sync.ip_country]
enabled = true
cron = "0 3 2 * *"
max_attempts = 3

[tasks.sync.ip_city]
enabled = true
cron = "30 3 2 * *"
max_attempts = 3

[tasks.sync.mac]
enabled = true
cron = "0 4 * * SUN"
max_attempts = 3
```

Configuration rules:

Relative `database_path` resolves under `YELLOW_DOG_DATA_DIR`.

Invalid cron expressions should prevent task scheduler startup and show a clear configuration error.

If `[tasks] enabled = false`, the UI remains visible but scheduled execution is disabled.

Manual “Run Now” may remain available when scheduling is disabled, unless explicitly disabled by config.

## 8.7 Observability

Add telemetry events:

```elixir
[:yellow_dog, :tasks, :sync, :start]
[:yellow_dog, :tasks, :sync, :stop]
[:yellow_dog, :tasks, :sync, :exception]
```

Metadata:

```elixir
%{
  task: :ip_city | :ip_country | :mac | :region,
  source: "db-ip" | "wireshark" | "region-provider",
  job_id: integer(),
  attempt: integer(),
  records: integer() | nil,
  file_size: integer() | nil
}
```

Oban itself includes telemetry integration, so YellowDog should attach task-specific telemetry handlers and expose task health in the console or logs. ([Hexdocs][14])

## 8.8 Security and Safety

The task UI must remain behind the existing console authentication pipeline.

Only allow known task types and known worker modules.

Do not allow arbitrary module names or arbitrary job args from the UI.

Validate cron expressions.

Validate downloaded files before replacing current files.

Use atomic file replacement:

Download to temporary file.

Validate temporary file.

Backup current file.

Rename temporary file into place.

Reload runtime database.

Remove old backup only after successful reload.

Avoid logging full URLs if credentials are ever supported.

Preserve attribution information for external datasets shown in existing UI.

## 9. Technical Design

## 9.1 Proposed Module Layout

Recommended new umbrella app:

```text
apps/yellow_dog_tasks/
  mix.exs
  lib/
    yellow_dog/
      tasks.ex
      tasks/
        application.ex
        repo.ex
        config.ex
        scheduler.ex
        task_status.ex
        data_sync.ex
        workers/
          sync_region_data_worker.ex
          sync_ip_database_worker.ex
          sync_mac_database_worker.ex
        region_data/
          provider.ex
          file_provider.ex
          store.ex
          validator.ex
  priv/
    repo/
      migrations/
        *_add_oban_jobs.exs
```

Console UI additions:

```text
apps/yellow_dog_console/lib/yellow_dog/console/live/tasks_live/index.ex
apps/yellow_dog_console/lib/yellow_dog/console/live/tasks_live/show.ex
apps/yellow_dog_console/lib/yellow_dog/console/live/tasks_live/components.ex
```

Router addition:

```elixir
live "/system/tasks", TasksLive.Index
live "/system/tasks/:task", TasksLive.Show
```

## 9.2 Worker Contracts

### `SyncIpDatabaseWorker`

```elixir
defmodule YellowDog.Tasks.Workers.SyncIpDatabaseWorker do
  use Oban.Worker,
    queue: :data_sync,
    max_attempts: 3,
    unique: [
      period: 3600,
      fields: [:worker, :queue, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => type}}) when type in ["city", "country"] do
    GeoIpDb.Database.download(String.to_existing_atom(type))
  end
end
```

### `SyncMacDatabaseWorker`

```elixir
defmodule YellowDog.Tasks.Workers.SyncMacDatabaseWorker do
  use Oban.Worker,
    queue: :data_sync,
    max_attempts: 3,
    unique: [
      period: 3600,
      fields: [:worker, :queue],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    YellowDog.Fingerprint.OuiDatabase.download()
  end
end
```

### `SyncRegionDataWorker`

```elixir
defmodule YellowDog.Tasks.Workers.SyncRegionDataWorker do
  use Oban.Worker,
    queue: :data_sync,
    max_attempts: 3,
    unique: [
      period: 3600,
      fields: [:worker, :queue],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    YellowDog.Tasks.RegionData.Store.sync()
  end
end
```

The final implementation should wrap these calls in validation, telemetry, and atomic file update logic rather than directly trusting downloaded data.

## 10. Data Model

## 10.1 Oban Tables

Use standard Oban tables created by Oban migration.

Primary job history source:

```text
oban_jobs
```

## 10.2 Optional Task Metadata Table

Add a YellowDog-owned metadata table to make the UI faster and independent from raw Oban history queries.

```text
yellow_dog_task_runs
```

Fields:

```text
id
task_key
source
status
oban_job_id
started_at
finished_at
duration_ms
records_count
file_size
version
error_class
error_message
metadata_json
inserted_at
updated_at
```

This table is optional for MVP. The MVP can derive status from `oban_jobs` plus each database module’s existing `info` or metadata functions.

## 11. Success Metrics

The feature is successful when:

IP database age is normally less than 35 days.

MAC/OUI database age is normally less than 10 days.

Operators can identify task health from the console in one page.

Manual sync actions no longer block LiveView processes.

A failed sync does not corrupt or replace the last working database.

Duplicate syncs for the same dataset are prevented during normal operation.

All sync jobs have durable history, retry state, and error visibility.

## 12. Acceptance Criteria

### Oban Foundation

The application boots with Oban enabled.

The Oban jobs table is created through migration.

The task Repo uses a database under `YELLOW_DOG_DATA_DIR` by default.

Test config uses Oban manual testing mode.

`data_sync` queue concurrency defaults to `1`.

### Scheduled Jobs

Region sync, IP country sync, IP city sync, and MAC sync are registered as scheduled jobs.

Cron schedule and timezone are configurable.

Disabled tasks are not scheduled.

Changing schedule through config is applied on restart.

### Manual Jobs

Admin can click “Run Now” for each task.

Manual execution enqueues an Oban job.

Duplicate manual clicks do not create unbounded duplicate jobs.

Manual job status is visible in the task UI.

### IP Database Sync

Successful IP country sync downloads, validates, replaces, and reloads the country MMDB.

Successful IP city sync downloads, validates, replaces, and reloads the city MMDB.

The `/system/ip-database` page reflects the updated file metadata.

Failed sync leaves the previous database active.

### MAC Database Sync

Successful MAC sync downloads, validates, replaces, and reloads `manuf.txt`.

The `/system/mac-database` page reflects updated source, entry count, and file metadata.

Failed sync leaves the previous OUI database active or compiled fallback active.

### Region Data Sync

Successful region sync stores normalized region data.

Region metadata includes source, record count, and last sync time.

Failed region sync leaves previous region data active.

### Observability

Each sync emits start, stop, and exception telemetry.

Recent jobs are visible in the UI.

Error summaries are visible without reading server logs.

Full stack traces remain available in logs for maintainers.

### Tests

Worker tests cover success and failure paths.

Config parsing tests cover enabled, disabled, invalid cron, and timezone cases.

LiveView tests cover run-now actions and status rendering.

File update tests prove failed validation does not replace existing files.

Oban uniqueness tests prevent duplicate jobs for the same task.

## 13. Release Plan

### Phase 1: Foundation

Add `yellow_dog_tasks` app.

Add Repo and Oban dependencies.

Add migration and runtime database path resolution.

Add Oban supervision.

Add test support.

### Phase 2: Workers

Implement IP database sync worker.

Implement MAC/OUI sync worker.

Implement initial region data sync worker with provider behavior.

Add telemetry events.

Add atomic file update utilities.

### Phase 3: Scheduling

Add default cron schedules.

Add TOML configuration mapping.

Add enable/disable support.

Add validation for cron/timezone/task config.

### Phase 4: Console UI

Add `/system/tasks`.

Add task overview cards.

Add job history table.

Add run-now/retry/cancel actions.

Link existing IP and MAC database pages to task status.

### Phase 5: Hardening

Add failure-mode tests.

Add distributed-node safeguards.

Add backup/rollback retention policy.

Add operator documentation.

Add migration and upgrade notes.

## 14. Risks and Open Questions

### 14.1 Region Data Source

The repository has clear IP and MAC database sources, but the desired “region data” source is not yet explicit. The PRD assumes normalized country/subdivision/city metadata, but the product owner should choose the authoritative provider.

Recommendation:

Start with a pluggable provider behavior and implement one default provider.

### 14.2 Oban Database Engine

SQLite is the recommended default because YellowDog appears to use a local data-directory deployment model, but PostgreSQL should remain an option for clustered production deployments.

### 14.3 Runtime Schedule Editing

Open-source Oban Cron is static at boot. If the product requires schedule edits to apply immediately across a cluster without restart, that is a future enhancement requiring either custom scheduler management or Oban Pro DynamicCron. ([Hexdocs][11])

### 14.4 Distributed Deployments

If multiple YellowDog nodes share the same data directory, task execution must avoid simultaneous file replacement. Queue concurrency helps inside one Oban instance, but distributed file safety may also require lock files, leader election, or a single scheduler node.

### 14.5 External Source Availability

DB-IP and Wireshark downloads can fail, change format, or become temporarily unavailable. Workers must treat download/parse failure as a normal retryable condition and must not corrupt active data.

## 15. Recommended MVP

The smallest useful release should include:

Oban + SQLite task database.

`data_sync` queue with concurrency `1`.

Three workers:

`SyncIpDatabaseWorker`

`SyncMacDatabaseWorker`

`SyncRegionDataWorker`

Default cron schedules.

Manual “Run Now” buttons.

Task overview UI at `/system/tasks`.

Integration links from existing IP/MAC database pages.

Atomic download-validate-reload behavior.

Job history and last error display.

This MVP directly solves the operational need: YellowDog can automatically keep region, IP, and MAC databases synchronized through durable scheduled Oban tasks, while giving administrators visibility and manual control from the console.

[1]: https://raw.githubusercontent.com/gsmlg-dev/yellow-dog/main/apps/yellow_dog_console/lib/yellow_dog/console/router.ex "raw.githubusercontent.com"
[2]: https://github.com/gsmlg-dev/yellow-dog "GitHub - gsmlg-dev/yellow-dog: YellowDog is a DNS, DHCPv4, DHCPv6 and mDNS Server written in erlang/elixir. · GitHub"
[3]: https://raw.githubusercontent.com/gsmlg-dev/yellow-dog/main/apps/geo_ip_db/mix.exs "raw.githubusercontent.com"
[4]: https://raw.githubusercontent.com/gsmlg-dev/yellow-dog/main/apps/geo_ip_db/lib/geo_ip_db/database.ex "raw.githubusercontent.com"
[5]: https://raw.githubusercontent.com/gsmlg-dev/yellow-dog/main/apps/yellow_dog_fingerprint/mix.exs "raw.githubusercontent.com"
[6]: https://raw.githubusercontent.com/gsmlg-dev/yellow-dog/main/apps/yellow_dog_console/lib/yellow_dog/console/application.ex "raw.githubusercontent.com"
[7]: https://raw.githubusercontent.com/gsmlg-dev/yellow-dog/main/config/config.exs "raw.githubusercontent.com"
[8]: https://hexdocs.pm/oban/Oban.Job.html "Oban.Job — Oban v2.23.0"
[9]: https://raw.githubusercontent.com/gsmlg-dev/yellow-dog/main/config/runtime.exs "raw.githubusercontent.com"
[10]: https://hexdocs.pm/oban/installation.html "Installation — Oban v2.23.0"
[11]: https://hexdocs.pm/oban/Oban.Plugins.Cron.html "Oban.Plugins.Cron — Oban v2.23.0"
[12]: https://raw.githubusercontent.com/gsmlg-dev/yellow-dog/main/apps/yellow_dog_fingerprint/lib/yellow_dog/fingerprint/oui_database.ex "raw.githubusercontent.com"
[13]: https://hexdocs.pm/oban/unique_jobs.html "Unique Jobs — Oban v2.23.0"
[14]: https://hexdocs.pm/oban/Oban.html "Oban — Oban v2.23.0"
