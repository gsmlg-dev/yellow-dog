defmodule YellowDog.Console.ProcessMapLive do
  @moduledoc """
  LiveView page for viewing Erlang process supervision trees.

  Displays an interactive SVG tree diagram of YellowDog application
  processes starting from YellowDog.Supervisor.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.FormatHelper, only: [format_time: 1]

  alias YellowDog.Console.ProcessInspector

  @refresh_interval 5_000
  @node_width 160
  @node_height 36
  @h_spacing 20
  @v_spacing 50
  @padding 40

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh_tree)
    end

    tree = ProcessInspector.get_tree()

    # Start with root node and immediate children (app supervisors) expanded
    initial_expanded =
      if tree do
        # Add root pid if it's a real pid
        pids = if is_pid(tree.pid), do: [tree.pid], else: []

        # Add all immediate children pids (the app supervisors)
        child_pids =
          for child <- Map.get(tree, :children, []),
              is_pid(child.pid),
              do: child.pid

        MapSet.new(pids ++ child_pids)
      else
        MapSet.new()
      end

    layout_opts = [
      node_width: @node_width,
      node_height: @node_height,
      h_spacing: @h_spacing,
      v_spacing: @v_spacing,
      padding: @padding,
      expanded_pids: initial_expanded
    ]

    {tree_with_layout, svg_width, svg_height} =
      if tree do
        laid_out = ProcessInspector.calculate_layout(tree, layout_opts)
        {w, h} = ProcessInspector.calculate_dimensions(laid_out, layout_opts)
        {laid_out, w, h}
      else
        {nil, 600, 300}
      end

    {:ok,
     assign(socket,
       page_title: "Process Map",
       tree: tree_with_layout,
       svg_width: svg_width,
       svg_height: svg_height,
       padding: @padding,
       node_width: @node_width,
       node_height: @node_height,
       selected_pid: nil,
       selected_status: nil,
       last_refresh: DateTime.utc_now(),
       show_status_panel: false,
       loading_status: false,
       node_count: ProcessInspector.count_nodes(tree),
       expanded_pids: initial_expanded
     )}
  end

  @impl true
  def handle_info(:refresh_tree, socket) do
    tree = ProcessInspector.get_tree()

    layout_opts = [
      node_width: @node_width,
      node_height: @node_height,
      h_spacing: @h_spacing,
      v_spacing: @v_spacing,
      padding: @padding,
      expanded_pids: socket.assigns.expanded_pids
    ]

    {tree_with_layout, svg_width, svg_height} =
      if tree do
        laid_out = ProcessInspector.calculate_layout(tree, layout_opts)
        {w, h} = ProcessInspector.calculate_dimensions(laid_out, layout_opts)
        {laid_out, w, h}
      else
        {nil, 600, 300}
      end

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

    {:noreply,
     assign(socket,
       tree: tree_with_layout,
       svg_width: svg_width,
       svg_height: svg_height,
       last_refresh: DateTime.utc_now(),
       node_count: ProcessInspector.count_nodes(tree)
     )}
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
    case ProcessInspector.parse_pid(pid_string) do
      {:ok, pid} ->
        expanded_pids = socket.assigns.expanded_pids

        new_expanded =
          if MapSet.member?(expanded_pids, pid) do
            MapSet.delete(expanded_pids, pid)
          else
            MapSet.put(expanded_pids, pid)
          end

        # Recalculate layout with new expansion state
        tree = ProcessInspector.get_tree()

        layout_opts = [
          node_width: @node_width,
          node_height: @node_height,
          h_spacing: @h_spacing,
          v_spacing: @v_spacing,
          padding: @padding,
          expanded_pids: new_expanded
        ]

        {tree_with_layout, svg_width, svg_height} =
          if tree do
            laid_out = ProcessInspector.calculate_layout(tree, layout_opts)
            {w, h} = ProcessInspector.calculate_dimensions(laid_out, layout_opts)
            {laid_out, w, h}
          else
            {nil, 600, 300}
          end

        {:noreply,
         assign(socket,
           expanded_pids: new_expanded,
           tree: tree_with_layout,
           svg_width: svg_width,
           svg_height: svg_height
         )}

      {:error, :invalid_pid} ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="flex flex-col gap-4 h-full">
        <!-- Header -->
        <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
          <div>
            <h1 class="text-2xl font-bold">Process Map</h1>
            <p class="text-base-content/70">
              Supervision trees for all YellowDog applications
            </p>
          </div>
          <div class="flex items-center gap-4">
            <div class="stats stats-horizontal shadow bg-base-200">
              <div class="stat py-2 px-4">
                <div class="stat-title text-xs">Processes</div>
                <div class="stat-value text-lg">{@node_count}</div>
              </div>
              <div class="stat py-2 px-4">
                <div class="stat-title text-xs">Last Refresh</div>
                <div class="stat-value text-lg">{format_time(@last_refresh)}</div>
              </div>
            </div>
          </div>
        </div>
        
    <!-- SVG Tree Container -->
        <div class="flex-1 relative">
          <div class={[
            "card bg-base-200 shadow-lg overflow-auto h-full",
            @show_status_panel && "lg:mr-96"
          ]}>
            <div class="card-body p-4">
              <%= if @tree do %>
                <svg
                  width={@svg_width}
                  height={@svg_height}
                  class="mx-auto"
                  style="min-width: 100%;"
                >
                  <g transform={"translate(#{@padding}, #{@padding})"}>
                    <!-- Draw connections first (behind nodes) -->
                    <.draw_connections
                      node={@tree}
                      node_width={@node_width}
                      node_height={@node_height}
                    />
                    <!-- Draw nodes -->
                    <.draw_nodes
                      node={@tree}
                      selected_pid={@selected_pid}
                      node_width={@node_width}
                      node_height={@node_height}
                    />
                  </g>
                </svg>
              <% else %>
                <.empty_state />
              <% end %>
            </div>
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

  # SVG Drawing Components

  attr :node, :map, required: true
  attr :node_width, :integer, required: true
  attr :node_height, :integer, required: true

  defp draw_connections(assigns) do
    # Only draw connections if node is expanded and has children
    children = if assigns.node[:expanded], do: assigns.node.children, else: []
    assigns = assign(assigns, :visible_children, children)

    ~H"""
    <%= for child <- @visible_children do %>
      <!-- Horizontal connection: right side of parent to left side of child -->
      <path
        d={"M #{@node.x + @node_width} #{@node.y + @node_height / 2} C #{@node.x + @node_width + 30} #{@node.y + @node_height / 2}, #{child.x - 30} #{child.y + @node_height / 2}, #{child.x} #{child.y + @node_height / 2}"}
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        class="text-base-content/30"
      />
      <.draw_connections node={child} node_width={@node_width} node_height={@node_height} />
    <% end %>
    """
  end

  attr :node, :map, required: true
  attr :selected_pid, :any, required: true
  attr :node_width, :integer, required: true
  attr :node_height, :integer, required: true

  defp draw_nodes(assigns) do
    pid_string = if is_pid(assigns.node.pid), do: inspect(assigns.node.pid), else: ""
    is_selected = assigns.selected_pid == assigns.node.pid
    is_supervisor = assigns.node.type == :supervisor
    has_children = assigns.node.children != []
    is_expanded = assigns.node[:expanded] == true
    visible_children = if is_expanded, do: assigns.node.children, else: []

    assigns =
      assigns
      |> assign(:pid_string, pid_string)
      |> assign(:is_selected, is_selected)
      |> assign(:is_supervisor, is_supervisor)
      |> assign(:has_children, has_children)
      |> assign(:is_expanded, is_expanded)
      |> assign(:visible_children, visible_children)

    ~H"""
    <g class="cursor-pointer">
      <!-- Node background (clickable for selection) -->
      <rect
        x={@node.x}
        y={@node.y}
        width={@node_width}
        height={@node_height}
        rx="6"
        ry="6"
        class={[
          "transition-all duration-150",
          @is_supervisor && "fill-primary/20 stroke-primary",
          !@is_supervisor && "fill-secondary/20 stroke-secondary",
          @is_selected && "fill-accent/30 stroke-accent stroke-2",
          @node.status == :undefined && "fill-base-300 stroke-base-content/30",
          @node.status == :restarting && "fill-warning/20 stroke-warning"
        ]}
        stroke-width={if @is_selected, do: "3", else: "2"}
        phx-click="select_node"
        phx-value-pid={@pid_string}
      />
      
    <!-- Type indicator -->
      <rect
        x={@node.x}
        y={@node.y}
        width="24"
        height={@node_height}
        rx="6"
        ry="6"
        class={[
          @is_supervisor && "fill-primary",
          !@is_supervisor && "fill-secondary",
          @node.status == :undefined && "fill-base-content/30",
          @node.status == :restarting && "fill-warning"
        ]}
        phx-click="select_node"
        phx-value-pid={@pid_string}
      />
      <rect
        x={@node.x + 18}
        y={@node.y}
        width="6"
        height={@node_height}
        class={[
          @is_supervisor && "fill-primary",
          !@is_supervisor && "fill-secondary",
          @node.status == :undefined && "fill-base-content/30",
          @node.status == :restarting && "fill-warning"
        ]}
        phx-click="select_node"
        phx-value-pid={@pid_string}
      />
      <text
        x={@node.x + 12}
        y={@node.y + @node_height / 2 + 1}
        text-anchor="middle"
        dominant-baseline="middle"
        class="fill-primary-content text-[10px] font-bold pointer-events-none"
      >
        {if @is_supervisor, do: "S", else: "W"}
      </text>
      
    <!-- Label -->
      <text
        x={@node.x + 32}
        y={@node.y + @node_height / 2}
        dominant-baseline="middle"
        class="fill-base-content text-xs font-medium pointer-events-none"
      >
        {truncate_label(@node.label, 14)}
      </text>
      
    <!-- Expand/Collapse button (only for nodes with children) -->
      <%= if @has_children do %>
        <g
          phx-click="toggle_expand"
          phx-value-pid={@pid_string}
          class="cursor-pointer"
        >
          <circle
            cx={@node.x + @node_width - 12}
            cy={@node.y + @node_height / 2}
            r="8"
            class="fill-base-200 stroke-base-content/50 hover:fill-base-300"
            stroke-width="1"
          />
          <text
            x={@node.x + @node_width - 12}
            y={@node.y + @node_height / 2 + 1}
            text-anchor="middle"
            dominant-baseline="middle"
            class="fill-base-content text-[10px] font-bold pointer-events-none"
          >
            {if @is_expanded, do: "−", else: "+"}
          </text>
        </g>
      <% else %>
        <!-- Status indicator dot (only for leaf nodes) -->
        <circle
          cx={@node.x + @node_width - 12}
          cy={@node.y + @node_height / 2}
          r="4"
          class={[
            @node.status == :running && "fill-success",
            @node.status == :restarting && "fill-warning animate-pulse",
            @node.status == :undefined && "fill-base-content/30"
          ]}
        />
      <% end %>
    </g>

    <!-- Draw child nodes recursively (only if expanded) -->
    <%= for child <- @visible_children do %>
      <.draw_nodes
        node={child}
        selected_pid={@selected_pid}
        node_width={@node_width}
        node_height={@node_height}
      />
    <% end %>
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
          <button
            class="btn btn-ghost btn-sm btn-circle"
            phx-click="close_panel"
            aria-label="Close panel"
          >
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
              <.status_field label="PID" value={inspect(@status.pid)} mono={true} />
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
        <span class={[
          "text-sm font-medium",
          @mono && "font-mono text-xs bg-base-200 px-2 py-1 rounded"
        ]}>
          {@value}
        </span>
      <% end %>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 text-center">
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
      <h2 class="text-xl font-bold mt-4">YellowDog.Supervisor Not Found</h2>
      <p class="text-base-content/70 max-w-md">
        The YellowDog application supervisor is not running. Start the application to see its process tree.
      </p>
    </div>
    """
  end

  # Helper functions

  defp truncate_label(label, max_length) do
    if String.length(label) > max_length do
      String.slice(label, 0, max_length - 2) <> ".."
    else
      label
    end
  end
end
