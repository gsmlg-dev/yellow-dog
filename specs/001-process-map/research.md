# Research: Process Map

**Feature**: 001-process-map
**Date**: 2024-12-28

## 1. OTP Supervision Tree Introspection

### Decision
Use `Application.get_env/2` to get application supervisor, then recursively traverse using `:supervisor.which_children/1`.

### Rationale
- OTP provides built-in introspection via `:supervisor.which_children/1`
- Each YellowDog application exposes its root supervisor
- No external dependencies needed

### Implementation Pattern

```elixir
defmodule YellowDog.Console.ProcessInspector do
  @yellowdog_apps [
    :yellow_dog,
    :yellow_dog_dns,
    :yellow_dog_dhcpv4,
    :yellow_dog_dhcpv6,
    :yellow_dog_mdns,
    :yellow_dog_console,
    :yellow_dog_telemetry
  ]

  @doc "Get all YellowDog application supervision trees"
  def get_trees do
    @yellowdog_apps
    |> Enum.filter(&application_started?/1)
    |> Enum.map(&build_app_tree/1)
  end

  defp application_started?(app) do
    case Application.get_application(app) do
      nil -> false
      _ -> Application.started_applications() |> Enum.any?(fn {name, _, _} -> name == app end)
    end
  end

  defp build_app_tree(app) do
    case get_app_supervisor(app) do
      nil -> %{app: app, supervisor: nil, children: []}
      pid -> %{app: app, supervisor: pid, children: get_children(pid)}
    end
  end

  defp get_app_supervisor(app) do
    # Convention: YellowDog apps use <AppModule>.Supervisor or <AppModule>.Application
    # Try to find the root supervisor
    case Process.whereis(Module.concat([Macro.camelize(to_string(app)), Supervisor])) do
      nil -> find_supervisor_from_application(app)
      pid -> pid
    end
  end

  defp get_children(supervisor_pid) when is_pid(supervisor_pid) do
    case :supervisor.which_children(supervisor_pid) do
      children when is_list(children) ->
        Enum.map(children, fn {id, pid, type, _modules} ->
          child_info = %{
            id: id,
            pid: pid,
            type: type,
            children: if(type == :supervisor and is_pid(pid), do: get_children(pid), else: [])
          }
          child_info
        end)
      _ -> []
    end
  rescue
    _ -> []
  end
end
```

### Alternatives Considered
- **Observer module**: Too heavyweight, designed for GUI not web
- **sys module**: Lower level, requires more code
- **Third-party libraries**: Unnecessary complexity

---

## 2. Process Information Retrieval

### Decision
Use `:erlang.process_info/2` with specific keys for targeted information retrieval.

### Rationale
- `:erlang.process_info/1` returns all info but is expensive
- `:erlang.process_info/2` allows selecting specific fields
- Selected fields: `[:registered_name, :current_function, :message_queue_len, :memory, :status, :links, :monitors]`

### Implementation Pattern

```elixir
@process_info_keys [
  :registered_name,
  :current_function,
  :message_queue_len,
  :memory,
  :status,
  :links,
  :monitors,
  :reductions,
  :current_stacktrace
]

def get_process_status(pid) when is_pid(pid) do
  case :erlang.process_info(pid, @process_info_keys) do
    nil ->
      {:error, :process_not_found}
    info ->
      {:ok, %{
        pid: pid,
        registered_name: Keyword.get(info, :registered_name),
        current_function: format_mfa(Keyword.get(info, :current_function)),
        message_queue_len: Keyword.get(info, :message_queue_len, 0),
        memory: Keyword.get(info, :memory, 0),
        status: Keyword.get(info, :status),
        links: Keyword.get(info, :links, []),
        monitors: Keyword.get(info, :monitors, []),
        reductions: Keyword.get(info, :reductions, 0)
      }}
  end
end

defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
defp format_mfa(nil), do: "N/A"
```

### Performance Considerations
- Batch requests when possible
- Cache results briefly (500ms) for rapid clicking
- Async fetch for status panel

---

## 3. Tree Visualization in LiveView

### Decision
Use pure HTML/CSS nested lists with DaisyUI collapse component for expand/collapse.

### Rationale
- No JavaScript library needed
- Works with LiveView's DOM patching
- DaisyUI provides collapse component
- Accessible and semantic HTML

### Implementation Pattern

```heex
<%!-- Tree node component --%>
<div class="tree-node ml-4">
  <%= if has_children?(@node) do %>
    <details open={@expanded}>
      <summary
        class="cursor-pointer flex items-center gap-2 py-1 hover:bg-base-200 rounded"
        phx-click="select_node"
        phx-value-pid={inspect(@node.pid)}
      >
        <span class={"badge badge-sm " <> type_badge(@node.type)}>
          <%= node_label(@node) %>
        </span>
        <span class="text-xs text-base-content/60">
          <%= inspect(@node.pid) %>
        </span>
      </summary>
      <div class="ml-4 border-l border-base-300 pl-2">
        <%= for child <- @node.children do %>
          <.tree_node node={child} selected_pid={@selected_pid} />
        <% end %>
      </div>
    </details>
  <% else %>
    <div
      class="flex items-center gap-2 py-1 hover:bg-base-200 rounded cursor-pointer"
      phx-click="select_node"
      phx-value-pid={inspect(@node.pid)}
    >
      <span class={"badge badge-sm " <> type_badge(@node.type)}>
        <%= node_label(@node) %>
      </span>
      <span class="text-xs text-base-content/60">
        <%= inspect(@node.pid) %>
      </span>
    </div>
  <% end %>
</div>
```

### CSS Enhancements

```css
/* Tree visualization styles */
.tree-node details > summary::before {
  content: "▶";
  display: inline-block;
  margin-right: 0.25rem;
  transition: transform 0.2s;
}

.tree-node details[open] > summary::before {
  transform: rotate(90deg);
}

.tree-node .selected {
  @apply bg-primary/10 ring-1 ring-primary;
}
```

### Alternatives Considered
- **D3.js**: Overkill, requires JavaScript integration
- **Graphviz/Mermaid**: Static rendering, not interactive
- **SVG-based tree**: Complex, harder to integrate with LiveView

---

## 4. Real-time Updates

### Decision
Use polling with `:timer.send_interval/2` at 5-second intervals.

### Rationale
- Process changes are infrequent (seconds, not milliseconds)
- 5-second refresh matches spec requirement ("within 5 seconds")
- Polling is simpler than process monitoring
- User can manually refresh if needed

### Implementation Pattern

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    # Refresh tree every 5 seconds
    :timer.send_interval(5_000, self(), :refresh_tree)
  end

  trees = ProcessInspector.get_trees()

  {:ok, assign(socket,
    page_title: "Process Map",
    trees: trees,
    selected_pid: nil,
    selected_status: nil,
    last_refresh: DateTime.utc_now()
  )}
end

def handle_info(:refresh_tree, socket) do
  trees = ProcessInspector.get_trees()
  {:noreply, assign(socket, trees: trees, last_refresh: DateTime.utc_now())}
end
```

### Edge Cases
- **Process terminates while selected**: Clear selection, show "Process terminated" message
- **New processes appear**: Automatically visible on next refresh
- **Large tree changes**: Preserve expansion state across refreshes using node IDs

### Alternatives Considered
- **Process monitors**: Complex for multiple processes, noisy
- **PubSub events**: Would require instrumenting all supervisors
- **WebSocket push**: Overkill for this use case

---

## 5. Visual Distinction for Node Types

### Decision
Use DaisyUI badges with distinct colors for supervisor vs worker processes.

### Implementation

| Type | Badge Class | Icon |
|------|-------------|------|
| Supervisor | `badge-primary` | ▼ (tree) |
| Worker | `badge-secondary` | ● (circle) |
| Application | `badge-accent` | ◆ (diamond) |

```elixir
defp type_badge(:supervisor), do: "badge-primary"
defp type_badge(:worker), do: "badge-secondary"
defp type_badge(:application), do: "badge-accent"
defp type_badge(_), do: "badge-ghost"
```

---

## Summary

| Research Area | Decision | Confidence |
|---------------|----------|------------|
| Tree introspection | `:supervisor.which_children/1` recursive | High |
| Process info | `:erlang.process_info/2` with specific keys | High |
| Tree UI | HTML/CSS nested lists with DaisyUI | High |
| Real-time updates | 5-second polling | High |
| Node styling | DaisyUI badges with type-based colors | High |

All research questions resolved. Ready for Phase 1 design.
