# Console Server Channel Prerequisite Report

Date: 2026-07-17

## Status

Implemented the narrow Console Server control-channel prerequisite for the
approved Task 9B canonical Sync publication and durable ConfigState receipt
contract.

## Transport And Authentication

- Mounted `YellowDog.Console.ServerSocket` at `/server/ws`; clients connect to
  `/server/ws/websocket`.
- The socket accepts only exact `token` and `server_id` params.
- `server_id` must be a nonempty valid UTF-8 value of at most 128 bytes and
  must resolve through `YellowDog.ManagementCore.get_server/1`.
- The shared token is read from
  `:yellow_dog_console, :management_token`. Runtime configuration populates it
  from `YELLOW_DOG_MANAGEMENT_TOKEN`.
- Missing or empty configured/provided tokens fail closed. Authentication
  compares SHA-256 hashes with `Plug.Crypto.secure_compare/2`; token values are
  never logged.
- The authenticated Server joins only `server:control:<server_id>`.
  `ServerSocket.id/1` remains `nil`, and management-release mode does not reject
  a valid registered Server.

## Canonical Sync Boundary

- `ServerChannel` accepts only the `sync` event with exact string keys
  `message` and `publication_sequence`.
- A private `ServerChannel.SyncCodec` uses literal module atoms,
  `Code.ensure_loaded?/1`, and `apply/3` for
  `YellowDog.Sync.Message.decode/1` and `encode/1`.
- Every message must decode and re-encode to the exact original bytes.
- The adapter returns only stable tags and bounded identity/target/status maps
  to channel logic. Sync structs and codec or exception reasons remain inside
  the adapter.
- `publication_sequence` must be positive for ConfigState and `nil` for every
  other wrapper.
- Valid non-ConfigState messages reply with `%{"accepted" => true}`. ConfigState
  replies with the direct durable ManagementCore receipt. Errors use stable
  string-key maps with empty details.
- There is no direct Sync dependency or compile edge in the Console channel.
  A direct `yellow_dog_sync` dependency should replace this temporary dynamic
  boundary after the protected Console `mix.exs` edit is resolved.

## Handshake And Presence

- `ServerConnections` is a supervised GenServer before the Endpoint. Its state
  is not publicly writable.
- Join creates a monitored candidate. The channel requires canonical Hello
  with an exact `Identity.Server`, followed by the first matching canonical
  Status, before promotion to active.
- Promotion atomically installs the candidate and closes the previous active
  channel. A replacement candidate cannot evict the active channel before its
  handshake completes.
- Public inspection includes `start_link`, candidate begin/join, activation,
  touch, disconnect, get/list, `connected?/1`, and test reset.
- Active records track channel PID and monitor, identity, Status,
  connection time, and last-seen time. Candidate termination cannot evict the
  active record.
- Heartbeat touches presence. Journal is reconciled through
  `ManagementCore.runtime_connected(:server, id, journal)` before acceptance.
  ConfigState calls `accept_config_state_publication/4` before returning the
  receipt.
- Result and Event are currently rejected as unsupported because this narrow
  prerequisite has no safe request-correlation or event owner.
- Active disconnect calls `runtime_disconnected/2` and marks the record
  offline. Broadcasts use only `management:server:<id>`.

## Verification

- TDD RED: 21 focused tests, 21 expected failures before production modules
  existed.
- Focused Server socket/channel/connection tests: 21 tests, 0 failures.
- Initial full Console suite: 7 doctests and 1,714 tests, 0 failures, 4 skipped.
- A repeated exact-current full run had one unrelated failure:
  `BootControllerTest` expected HTTP 200 but received 422
  `:invalid_transition` from persisted boot state. `mix test --failed`
  reproduced that single out-of-scope failure.
- `mix compile --warnings-as-errors --force`: passed.
- Scoped `mix format --check-formatted`: passed.
- Scoped strict Credo: five production files checked, no issues.
- `mix xref graph --label compile --source
  lib/yellow_dog/console/channels/server_channel.ex`: only the Console macro
  module is a compile dependency; no Sync edge.
- Asset build was not run because no asset source changed.

## Scope

This work did not modify, stage, or revert the four protected dirty files:

- `apps/yellow_dog_console/lib/yellow_dog/console/components/layouts.ex`
- `apps/yellow_dog_console/mix.exs`
- `apps/yellow_dog_console/test/yellow_dog/console/live/service_pages_live_test.exs`
- `mix.exs`

No Netman, LiveView/router, ManagementCore, Sync, agent, release, asset, or
protocol source was changed.

## 2026-07-18 Review Fix Evidence

### Corrected Control Boundary

- `ServerSocket` now accepts exactly `token`, `server_id`, and Phoenix socket
  `vsn`; only `vsn` `"2.0.0"` is supported.
- Candidate admission is configured and validated at 5,000 ms handshake
  timeout, 256 global candidates, and one candidate per concrete Server.
  Candidate timers and monitors are removed on activation, disconnect, DOWN,
  reset, replacement, and timeout without evicting an active connection.
- Periodic canonical Status is accepted only from the active channel PID.
  `ManagementCore.update_server_status/2` persists the concrete state before
  the bounded connection record changes or the channel acknowledges it.
- Registry calls fail closed with stable internal or not-connected outcomes.

### Correlated Management Transport

- Added `YellowDog.Console.ManagementTransport` as the Console-owned
  `YellowDog.Management.Transport` adapter and select it only while Console
  starts with ManagementCore present.
- Query and Command requests are validated by the dynamic Sync operation
  registry, encoded as canonical wrappers, and pushed only as event `"sync"`
  with exact `message` and `publication_sequence` keys.
- Pending requests are bounded at 128 per Server and correlated by request ID,
  target type, operation, and active channel PID. Pending state is removed
  before reply and cleared with typed timeout or not-connected errors on
  timeout, disconnect, reset, or replacement.
- Late, duplicate, wrong-operation, wrong-target, and stale-channel Results are
  ignored without mutation. Fully validated successful and typed error Results
  are returned to ManagementCore.
- ConfigDelivery is validated and handed to the current active Server without
  treating handoff as application.
- The dynamic codec now constructs Query, Command, and ConfigDelivery and
  summarizes Result without a direct Console-to-Sync compile dependency.
- Existing ConfigState durable receipt ordering and Journal activation
  reconciliation remain unchanged.

### Verification

- Focused socket/channel/connection/transport suite: 39 tests, 0 failures.
- ManagementCore transport contract suite: 5 tests, 0 failures.
- Full Console suite: 7 doctests and 1,732 tests; one known unrelated
  `BootControllerTest` failure and four skipped. The failure is the persisted
  boot-state HTTP 422 `:invalid_transition`, and `mix test --failed`
  reproduced that single failure.
- `mix compile --warnings-as-errors`: passed for the umbrella.
- Scoped `mix format --check-formatted`: passed.
- Strict Credo: 195 Console source files checked, no issues.
- Compile xref for `ServerChannel` and `ManagementTransport`: no Sync compile
  edge; `ServerChannel` retains only the Console macro compile dependency.
- `MIX_ENV=prod mix release yellow_dog_management_core --overwrite`: passed.
  A live release boot reported `ManagementTransport` configured with
  `ServerConnections` and Endpoint both running.

The protected dirty Console files, root `mix.exs`, concurrent ServerAgent work,
Netman, protocol schemas/parsers, releases, storage, and unrelated UI were not
modified or staged by this fix.
