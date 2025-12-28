# Data Model: Process Map

**Feature**: 001-process-map
**Date**: 2024-12-28

## Entities

### ApplicationTree

Represents the supervision tree for a single YellowDog application.

```elixir
%{
  app: atom(),           # e.g., :yellow_dog_dns
  app_label: String.t(), # e.g., "DNS"
  supervisor: pid() | nil,
  running: boolean(),
  children: [ProcessNode.t()]
}
```

**Validation Rules**:
- `app` must be one of the 7 YellowDog applications
- `supervisor` is nil if application not started
- `children` is empty list if no supervisor

### ProcessNode

Represents a single process in the supervision tree.

```elixir
%{
  id: term(),            # Supervisor child ID (atom, tuple, or reference)
  pid: pid() | :undefined | :restarting,
  type: :supervisor | :worker,
  modules: [module()],
  children: [ProcessNode.t()],  # Empty for workers

  # Display properties
  label: String.t(),     # Registered name or ID as string
  status: :running | :restarting | :undefined
}
```

**Validation Rules**:
- `type` must be `:supervisor` or `:worker`
- `children` only populated for `:supervisor` type
- `pid` can be `:undefined` (not started) or `:restarting`

### ProcessStatus

Detailed information about a process, fetched on-demand when user clicks a node.

```elixir
%{
  pid: pid(),
  registered_name: atom() | nil,
  current_function: String.t(),  # "Module.function/arity"
  status: atom(),                # :running, :waiting, :suspended, etc.
  message_queue_len: non_neg_integer(),
  memory: non_neg_integer(),     # Bytes
  reductions: non_neg_integer(),
  links: [pid()],
  monitors: [{:process, pid() | atom()}],

  # Computed properties
  memory_human: String.t(),      # "1.2 MB"
  alive: boolean()
}
```

**Validation Rules**:
- `message_queue_len` >= 0
- `memory` >= 0
- `alive` derived from `:erlang.is_process_alive/1`

---

## LiveView Assigns

### ProcessMapLive Socket Assigns

```elixir
%{
  # Page metadata
  page_title: "Process Map",

  # Tree data
  trees: [ApplicationTree.t()],

  # Selection state
  selected_pid: pid() | nil,
  selected_status: ProcessStatus.t() | nil,

  # Expansion state (preserved across refreshes)
  expanded_pids: MapSet.t(String.t()),  # PID strings for expanded supervisors

  # Refresh state
  last_refresh: DateTime.t(),
  refresh_interval: 5_000,  # ms

  # UI state
  show_status_panel: boolean(),
  loading_status: boolean()
}
```

---

## State Transitions

### Process Lifecycle

```
                    ┌─────────────┐
                    │   Started   │
                    └──────┬──────┘
                           │
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
    ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
    │   Running   │ │  Restarting │ │  Undefined  │
    └──────┬──────┘ └──────┬──────┘ └─────────────┘
           │               │
           ▼               ▼
    ┌─────────────┐ ┌─────────────┐
    │  Terminated │ │   Running   │
    └─────────────┘ └─────────────┘
```

### UI State Transitions

```
Page Load ──► Fetch Trees ──► Display Tree
                                  │
                    ┌─────────────┼─────────────┐
                    ▼             ▼             ▼
              Click Node    Expand/Collapse   Auto-refresh
                    │             │             │
                    ▼             ▼             ▼
              Fetch Status   Toggle Branch   Update Trees
                    │                         (preserve
                    ▼                          expansion)
              Show Panel ◄─────────────────────┘
```

---

## Relationships

```
ApplicationTree 1 ─────► 0..1 ProcessNode (supervisor)
                              │
ProcessNode 1 ─────────────► * ProcessNode (children)
                              │
                              ▼
ProcessNode 1 ─────────────► 1 ProcessStatus (on-demand)
```

---

## Type Specifications

```elixir
@type app_name :: :yellow_dog | :yellow_dog_dns | :yellow_dog_dhcpv4 |
                  :yellow_dog_dhcpv6 | :yellow_dog_mdns | :yellow_dog_console |
                  :yellow_dog_telemetry

@type node_type :: :supervisor | :worker

@type process_status :: :running | :waiting | :suspended | :exiting | :garbage_collecting

@type application_tree :: %{
  app: app_name(),
  app_label: String.t(),
  supervisor: pid() | nil,
  running: boolean(),
  children: [process_node()]
}

@type process_node :: %{
  id: term(),
  pid: pid() | :undefined | :restarting,
  type: node_type(),
  modules: [module()],
  children: [process_node()],
  label: String.t(),
  status: :running | :restarting | :undefined
}

@type process_status_info :: %{
  pid: pid(),
  registered_name: atom() | nil,
  current_function: String.t(),
  status: process_status(),
  message_queue_len: non_neg_integer(),
  memory: non_neg_integer(),
  reductions: non_neg_integer(),
  links: [pid()],
  monitors: [{:process, pid() | atom()}],
  memory_human: String.t(),
  alive: boolean()
}
```
