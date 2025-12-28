defmodule YellowDog.Console.ProcessMapLive do
  @moduledoc """
  LiveView page for viewing Erlang process supervision trees.

  Displays an interactive tree diagram of YellowDog application
  processes with click-to-view status functionality.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Console.ProcessInspector

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh_tree)
    end

    trees = ProcessInspector.get_trees()

    {:ok,
     assign(socket,
       page_title: "Process Map",
       trees: trees,
       selected_pid: nil,
       selected_status: nil,
       expanded_pids: MapSet.new(),
       last_refresh: DateTime.utc_now(),
       show_status_panel: false,
       loading_status: false
     )}
  end

  @impl true
  def handle_info(:refresh_tree, socket) do
    trees = ProcessInspector.get_trees()

    # If we have a selected process, check if it's still alive
    socket =
      if socket.assigns.selected_pid do
        case ProcessInspector.get_process_status(socket.assigns.selected_pid) do
          {:ok, status} ->
            assign(socket, selected_status: status)

          {:error, :process_not_found} ->
            assign(socket,
              selected_status: %{alive: false, error: "Process terminated"},
              show_status_panel: true
            )
        end
      else
        socket
      end

    {:noreply, assign(socket, trees: trees, last_refresh: DateTime.utc_now())}
  end

  @impl true
  def handle_event("select_node", %{"pid" => pid_string}, socket) do
    case ProcessInspector.parse_pid(pid_string) do
      {:ok, pid} ->
        socket = assign(socket, loading_status: true, selected_pid: pid)

        case ProcessInspector.get_process_status(pid) do
          {:ok, status} ->
            {:noreply,
             assign(socket,
               selected_status: status,
               show_status_panel: true,
               loading_status: false
             )}

          {:error, :process_not_found} ->
            {:noreply,
             assign(socket,
               selected_status: %{alive: false, error: "Process not found"},
               show_status_panel: true,
               loading_status: false
             )}
        end

      {:error, :invalid_pid} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, assign(socket, show_status_panel: false, selected_pid: nil, selected_status: nil)}
  end

  def handle_event("toggle_expand", %{"pid" => pid_string}, socket) do
    expanded_pids = socket.assigns.expanded_pids

    new_expanded =
      if MapSet.member?(expanded_pids, pid_string) do
        MapSet.delete(expanded_pids, pid_string)
      else
        MapSet.put(expanded_pids, pid_string)
      end

    {:noreply, assign(socket, expanded_pids: new_expanded)}
  end

  def handle_event("expand_all", _params, socket) do
    # Collect all supervisor PIDs
    all_pids =
      socket.assigns.trees
      |> Enum.flat_map(&collect_supervisor_pids/1)
      |> MapSet.new()

    {:noreply, assign(socket, expanded_pids: all_pids)}
  end

  def handle_event("collapse_all", _params, socket) do
    {:noreply, assign(socket, expanded_pids: MapSet.new())}
  end

  defp collect_supervisor_pids(%{supervisor: nil}), do: []

  defp collect_supervisor_pids(%{supervisor: sup_pid, children: children}) when is_pid(sup_pid) do
    [inspect(sup_pid) | Enum.flat_map(children, &collect_child_pids/1)]
  end

  defp collect_supervisor_pids(_), do: []

  defp collect_child_pids(%{type: :supervisor, pid: pid, children: children}) when is_pid(pid) do
    [inspect(pid) | Enum.flat_map(children, &collect_child_pids/1)]
  end

  defp collect_child_pids(_), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col gap-6">
        <!-- Header -->
        <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
          <div>
            <h1 class="text-2xl font-bold">Process Map</h1>
            <p class="text-base-content/70">
              Supervision tree diagram for YellowDog applications
            </p>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-sm text-base-content/60">
              Last refresh: {format_time(@last_refresh)}
            </span>
            <button class="btn btn-sm btn-ghost" phx-click="expand_all">
              Expand All
            </button>
            <button class="btn btn-sm btn-ghost" phx-click="collapse_all">
              Collapse All
            </button>
          </div>
        </div>
        
    <!-- Tree Container -->
        <div class="relative">
          <div class={["transition-all duration-300", @show_status_panel && "lg:mr-96"]}>
            <%= if Enum.empty?(@trees) do %>
              <.empty_state />
            <% else %>
              <div class="space-y-4">
                <%= for tree <- @trees do %>
                  <.application_tree
                    tree={tree}
                    expanded_pids={@expanded_pids}
                    selected_pid={@selected_pid}
                  />
                <% end %>
              </div>
            <% end %>
          </div>
          
    <!-- Status Panel -->
          <.status_panel
            :if={@show_status_panel}
            status={@selected_status}
            loading={@loading_status}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Function Components

  attr :tree, :map, required: true
  attr :expanded_pids, :any, required: true
  attr :selected_pid, :any, required: true

  defp application_tree(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body p-4">
        <div class="flex items-center gap-3">
          <span class={[
            "badge badge-lg",
            @tree.running && "badge-accent",
            !@tree.running && "badge-ghost"
          ]}>
            {@tree.app_label}
          </span>
          <span class="text-sm text-base-content/60">
            {@tree.app}
          </span>
          <%= if @tree.running do %>
            <span class="badge badge-success badge-sm">Running</span>
          <% else %>
            <span class="badge badge-ghost badge-sm">Not Started</span>
          <% end %>
        </div>

        <%= if @tree.running and @tree.supervisor do %>
          <div class="mt-4 ml-2 border-l-2 border-base-300 pl-4">
            <!-- Root supervisor -->
            <.tree_node
              node={
                %{
                  id: :root,
                  pid: @tree.supervisor,
                  type: :supervisor,
                  modules: [],
                  children: @tree.children,
                  label: "Supervisor",
                  status: :running
                }
              }
              expanded_pids={@expanded_pids}
              selected_pid={@selected_pid}
              depth={0}
            />
          </div>
        <% else %>
          <div class="mt-4 text-base-content/50 text-sm italic">
            Application not started - no processes to display
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :expanded_pids, :any, required: true
  attr :selected_pid, :any, required: true
  attr :depth, :integer, default: 0

  defp tree_node(assigns) do
    pid_string = if is_pid(assigns.node.pid), do: inspect(assigns.node.pid), else: ""
    is_expanded = MapSet.member?(assigns.expanded_pids, pid_string)
    has_children = assigns.node.type == :supervisor and length(assigns.node.children) > 0
    is_selected = assigns.selected_pid == assigns.node.pid

    assigns =
      assigns
      |> assign(:pid_string, pid_string)
      |> assign(:is_expanded, is_expanded)
      |> assign(:has_children, has_children)
      |> assign(:is_selected, is_selected)

    ~H"""
    <div class="tree-node">
      <div class={[
        "flex items-center gap-2 py-1.5 px-2 rounded-lg cursor-pointer transition-colors",
        "hover:bg-base-300",
        @is_selected && "bg-primary/10 ring-1 ring-primary"
      ]}>
        <!-- Expand/Collapse indicator -->
        <%= if @has_children do %>
          <button
            class="btn btn-ghost btn-xs btn-circle"
            phx-click="toggle_expand"
            phx-value-pid={@pid_string}
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class={["h-4 w-4 transition-transform", @is_expanded && "rotate-90"]}
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 5l7 7-7 7"
              />
            </svg>
          </button>
        <% else %>
          <div class="w-6"></div>
        <% end %>
        
    <!-- Node content (clickable for status) -->
        <div
          class="flex items-center gap-2 flex-1"
          phx-click="select_node"
          phx-value-pid={@pid_string}
        >
          <span class={[
            "badge badge-sm",
            @node.type == :supervisor && "badge-primary",
            @node.type == :worker && "badge-secondary"
          ]}>
            {if @node.type == :supervisor, do: "SUP", else: "WRK"}
          </span>
          <span class="font-medium text-sm">
            {@node.label}
          </span>
          <span class="text-xs text-base-content/50">
            {@pid_string}
          </span>
          <.status_badge status={@node.status} />
        </div>
      </div>
      
    <!-- Children -->
      <%= if @has_children and @is_expanded do %>
        <div class="ml-6 border-l-2 border-base-300 pl-4 mt-1">
          <%= for child <- @node.children do %>
            <.tree_node
              node={child}
              expanded_pids={@expanded_pids}
              selected_pid={@selected_pid}
              depth={@depth + 1}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-xs",
      @status == :running && "badge-success",
      @status == :restarting && "badge-warning",
      @status == :undefined && "badge-ghost"
    ]}>
      <%= case @status do %>
        <% :running -> %>
          running
        <% :restarting -> %>
          restarting
        <% :undefined -> %>
          undefined
      <% end %>
    </span>
    """
  end

  attr :status, :map, required: true
  attr :loading, :boolean, default: false

  defp status_panel(assigns) do
    ~H"""
    <div class="fixed lg:absolute right-0 top-0 w-full lg:w-96 h-full bg-base-100 shadow-xl border-l border-base-300 z-50 overflow-y-auto">
      <div class="p-4">
        <div class="flex justify-between items-center mb-4">
          <h3 class="text-lg font-bold">Process Status</h3>
          <button class="btn btn-ghost btn-sm btn-circle" phx-click="close_panel">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        </div>

        <%= if @loading do %>
          <div class="flex justify-center py-8">
            <span class="loading loading-spinner loading-lg"></span>
          </div>
        <% else %>
          <%= if @status[:alive] == false do %>
            <div class="alert alert-warning">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-6 w-6"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                />
              </svg>
              <span>{@status[:error] || "Process terminated"}</span>
            </div>
          <% else %>
            <div class="space-y-4">
              <.status_field label="PID" value={inspect(@status.pid)} />
              <.status_field
                label="Registered Name"
                value={(@status.registered_name && Atom.to_string(@status.registered_name)) || "None"}
              />
              <.status_field label="Status" value={@status.status} badge={true} />
              <.status_field label="Current Function" value={@status.current_function} mono={true} />
              <.status_field label="Message Queue" value={@status.message_queue_len} />
              <.status_field label="Memory" value={@status.memory_human} />
              <.status_field label="Reductions" value={format_number(@status.reductions)} />
              <.status_field label="Links" value={length(@status.links)} />
              <.status_field label="Monitors" value={length(@status.monitors)} />
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :badge, :boolean, default: false
  attr :mono, :boolean, default: false

  defp status_field(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <span class="text-xs text-base-content/60 uppercase tracking-wider">
        {@label}
      </span>
      <%= if @badge do %>
        <span class="badge badge-info">{@value}</span>
      <% else %>
        <span class={["text-sm font-medium", @mono && "font-mono text-xs"]}>
          {@value}
        </span>
      <% end %>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body items-center text-center py-12">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-16 w-16 text-base-content/30"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M4 5a1 1 0 011-1h14a1 1 0 011 1v2a1 1 0 01-1 1H5a1 1 0 01-1-1V5zM4 13a1 1 0 011-1h6a1 1 0 011 1v6a1 1 0 01-1 1H5a1 1 0 01-1-1v-6zM16 13a1 1 0 011-1h2a1 1 0 011 1v6a1 1 0 01-1 1h-2a1 1 0 01-1-1v-6z"
          />
        </svg>
        <h2 class="text-xl font-bold mt-4">No Processes Available</h2>
        <p class="text-base-content/70 max-w-md">
          No YellowDog applications are currently running. Start the applications to see their process trees.
        </p>
      </div>
    </div>
    """
  end

  # Helper functions

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(num), do: inspect(num)
end
