defmodule YellowDog.ManagementUI.ProcessMapLive do
  @moduledoc """
  LiveView page for viewing Erlang process supervision trees.

  Displays an interactive SVG tree diagram of YellowDog application
  processes starting from YellowDog.Management.Supervisor.
  """
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.ManagementUI.ProcessInspector

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

    initial_expanded =
      if tree do
        pids = if is_pid(tree.pid), do: [tree.pid], else: []

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
        {width, height} = ProcessInspector.calculate_dimensions(laid_out, layout_opts)
        {laid_out, width, height}
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
        {width, height} = ProcessInspector.calculate_dimensions(laid_out, layout_opts)
        {laid_out, width, height}
      else
        {nil, 600, 300}
      end

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
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket), do: handle_info(:refresh_tree, socket)

  def handle_event("select_node", %{"pid" => pid_string}, socket) do
    with {:ok, pid} <- ProcessInspector.parse_pid(pid_string),
         true <- ProcessInspector.contains_pid?(socket.assigns.tree, pid) do
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
    else
      _result -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_panel", _params, socket) do
    {:noreply, assign(socket, show_status_panel: false, selected_pid: nil, selected_status: nil)}
  end

  @impl true
  def handle_event("toggle_expand", %{"pid" => pid_string}, socket) do
    with {:ok, pid} <- ProcessInspector.parse_pid(pid_string),
         true <- ProcessInspector.contains_pid?(socket.assigns.tree, pid) do
      expanded_pids = socket.assigns.expanded_pids

      new_expanded =
        if MapSet.member?(expanded_pids, pid) do
          MapSet.delete(expanded_pids, pid)
        else
          MapSet.put(expanded_pids, pid)
        end

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
          {width, height} = ProcessInspector.calculate_dimensions(laid_out, layout_opts)
          {laid_out, width, height}
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
    else
      _result -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="process-map" class="flex flex-col gap-4 h-full">
        <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
          <div>
            <h1 class="text-2xl font-bold">Process Map</h1>
            <p class="text-on-surface-variant">
              Supervision tree for this Management runtime
            </p>
          </div>
          <div class="flex items-center gap-4">
            <button
              id="refresh-process-map"
              type="button"
              class="btn btn-primary btn-sm"
              phx-click="refresh"
            >Refresh</button>
            <div class="flex gap-4">
              <div class="bg-surface-container rounded-lg py-2 px-4 shadow">
                <div class="text-xs text-on-surface-variant">Processes</div>
                <div class="text-lg font-bold">{@node_count}</div>
              </div>
              <div class="bg-surface-container rounded-lg py-2 px-4 shadow">
                <div class="text-xs text-on-surface-variant">Last Refresh</div>
                <div class="text-lg font-bold">{format_time(@last_refresh)}</div>
              </div>
            </div>
          </div>
        </div>

        <div class="flex-1 relative">
          <div class={[
            "card bg-surface-container shadow-lg overflow-auto h-full",
            @show_status_panel && "lg:mr-96"
          ]}>
            <div class="card-body p-4">
              <%= if @tree do %>
                <svg
                  id="process-map-tree"
                  aria-label="Management supervision tree"
                  width={@svg_width}
                  height={@svg_height}
                  class="mx-auto"
                >
                  <g transform={"translate(#{@padding}, #{@padding})"}>
                    <.draw_connections
                      node={@tree}
                      node_width={@node_width}
                      node_height={@node_height}
                    />
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

  attr :node, :map, required: true
  attr :node_width, :integer, required: true
  attr :node_height, :integer, required: true

  defp draw_connections(assigns) do
    children = if assigns.node[:expanded], do: assigns.node.children, else: []
    assigns = assign(assigns, :visible_children, children)

    ~H"""
    <%= for child <- @visible_children do %>
      <path
        d={"M #{@node.x + @node_width} #{@node.y + @node_height / 2} C #{@node.x + @node_width + 30} #{@node.y + @node_height / 2}, #{child.x - 30} #{child.y + @node_height / 2}, #{child.x} #{child.y + @node_height / 2}"}
        fill="none"
        stroke="var(--color-on-surface-variant)"
        stroke-width="2"
        class="text-on-surface-variant"
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
      <rect
        x={@node.x}
        y={@node.y}
        width={@node_width}
        height={@node_height}
        rx="6"
        ry="6"
        data-process-node
        fill={node_fill(@node, @is_selected)}
        stroke={node_stroke(@node, @is_selected)}
        stroke-width={if @is_selected, do: "3", else: "2"}
        phx-click="select_node"
        phx-value-pid={@pid_string}
      />

      <rect
        x={@node.x}
        y={@node.y}
        width="24"
        height={@node_height}
        rx="6"
        ry="6"
        fill={node_stroke(@node, false)}
        phx-click="select_node"
        phx-value-pid={@pid_string}
      />
      <rect
        x={@node.x + 18}
        y={@node.y}
        width="6"
        height={@node_height}
        fill={node_stroke(@node, false)}
        phx-click="select_node"
        phx-value-pid={@pid_string}
      />
      <text
        x={@node.x + 12}
        y={@node.y + @node_height / 2 + 1}
        text-anchor="middle"
        dominant-baseline="middle"
        fill={if @is_supervisor, do: "var(--color-on-primary)", else: "var(--color-on-secondary)"}
        font-size="10"
        font-weight="700"
        pointer-events="none"
      >
        {if @is_supervisor, do: "S", else: "W"}
      </text>

      <text
        x={@node.x + 32}
        y={@node.y + @node_height / 2}
        dominant-baseline="middle"
        fill="var(--color-on-surface)"
        font-size="12"
        font-weight="500"
        pointer-events="none"
      >
        {truncate_label(@node.label, 14)}
      </text>

      <%= if @has_children do %>
        <g
          data-process-expand
          phx-click="toggle_expand"
          phx-value-pid={@pid_string}
          class="cursor-pointer"
        >
          <circle
            cx={@node.x + @node_width - 12}
            cy={@node.y + @node_height / 2}
            r="8"
            fill="var(--color-surface-container-high)"
            stroke="var(--color-outline)"
            stroke-width="1"
          />
          <text
            x={@node.x + @node_width - 12}
            y={@node.y + @node_height / 2 + 1}
            text-anchor="middle"
            dominant-baseline="middle"
            fill="var(--color-on-surface)"
            font-size="10"
            font-weight="700"
            pointer-events="none"
          >
            {if @is_expanded, do: "−", else: "+"}
          </text>
        </g>
      <% else %>
        <circle
          cx={@node.x + @node_width - 12}
          cy={@node.y + @node_height / 2}
          r="4"
          fill={status_fill(@node.status)}
          class={@node.status == :restarting && "animate-pulse"}
        />
      <% end %>
    </g>

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
    <div
      id="process-status-panel"
      class="fixed right-0 top-16 bottom-0 w-full lg:w-96 bg-surface shadow-xl border-l border-outline z-50 overflow-y-auto"
    >
      <div class="p-4">
        <div class="flex justify-between items-center mb-4">
          <h3 class="text-lg font-bold">Process Status</h3>
          <button
            class="btn btn-ghost btn-sm btn-circle"
            phx-click="close_panel"
            aria-label="Close panel"
          >
            <.dm_mdi name="close" class="h-5 w-5" />
          </button>
        </div>

        <%= if @loading do %>
          <div class="flex justify-center py-8">
            <span
              class="inline-block animate-spin rounded-full border-2 border-current border-t-transparent w-12 h-12"
              role="status"
            ></span>
          </div>
        <% else %>
          <%= if @status[:alive] == false do %>
            <div class="alert alert-warning">
              <.dm_mdi name="alert" class="h-6 w-6" />
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
      <span class="text-xs text-on-surface-variant uppercase tracking-wider">
        {@label}
      </span>
      <%= if @badge do %>
        <span class="badge badge-info">{@value}</span>
      <% else %>
        <span class={[
          "text-sm font-medium",
          @mono && "font-mono text-xs bg-surface-container px-2 py-1 rounded"
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
      <.dm_mdi name="sitemap" class="h-16 w-16 text-on-surface-variant" />
      <h2 class="text-xl font-bold mt-4">YellowDog.Management.Supervisor Not Found</h2>
      <p class="text-on-surface-variant max-w-md">
        The Management application supervisor is not running. Start the application to see its process tree.
      </p>
    </div>
    """
  end

  defp truncate_label(label, max_length) do
    if String.length(label) > max_length do
      String.slice(label, 0, max_length - 2) <> ".."
    else
      label
    end
  end

  defp format_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%H:%M:%S")

  defp node_fill(_node, true), do: "var(--color-tertiary-container)"
  defp node_fill(%{status: :undefined}, false), do: "var(--color-surface-container-high)"
  defp node_fill(%{status: :restarting}, false), do: "var(--color-warning-container)"
  defp node_fill(%{type: :supervisor}, false), do: "var(--color-primary-container)"
  defp node_fill(_node, false), do: "var(--color-secondary-container)"

  defp node_stroke(_node, true), do: "var(--color-tertiary)"
  defp node_stroke(%{status: :undefined}, false), do: "var(--color-outline)"
  defp node_stroke(%{status: :restarting}, false), do: "var(--color-warning)"
  defp node_stroke(%{type: :supervisor}, false), do: "var(--color-primary)"
  defp node_stroke(_node, false), do: "var(--color-secondary)"

  defp status_fill(:running), do: "var(--color-success)"
  defp status_fill(:restarting), do: "var(--color-warning)"
  defp status_fill(_status), do: "var(--color-outline)"
end
