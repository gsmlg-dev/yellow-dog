defmodule YellowDog.Console.NetmanLive.ResolvedLive do
  @moduledoc """
  Resolved server page for a connected Netman service instance.
  Shows DNS resolution configuration, upstream servers, cache stats, and real-time query log.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.NetmanRegistry

  @max_log_entries 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: NetmanRegistry.subscribe()
    {:ok, assign(socket, page_title: "Resolved Server")}
  end

  @impl true
  def handle_params(%{"node_id" => node_id}, _uri, socket) do
    # Unsubscribe from previous node's query log if navigating between nodes
    if old_id = socket.assigns[:node_id] do
      Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "netman:query_log:#{old_id}")
    end

    case NetmanRegistry.get(node_id) do
      {:ok, client} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netman:query_log:#{node_id}")
        end

        resolved = client[:resolved]

        {:noreply,
         assign(socket,
           node_id: node_id,
           client: client,
           resolved: resolved,
           query_log: (resolved && resolved["query_log"]) || [],
           page_title: "#{client.hostname} — Resolved"
         )}

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, "Netman node \"#{node_id}\" is not connected")
         |> push_navigate(to: "/netman")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center gap-2">
          <.link navigate={"/netman/#{@node_id}"} class="btn btn-ghost btn-sm btn-circle">
            <.dm_mdi name="arrow-left" class="w-5 h-5" />
          </.link>
          <div>
            <h1 class="text-4xl font-bold">Resolved Server</h1>
            <p class="mt-1 text-on-surface-variant">
              {@client.hostname} · <span class="font-mono text-sm">{@client.ip}</span>
            </p>
          </div>
        </div>

        <%= if @resolved do %>
          <.resolved_overview resolved={@resolved} />
          <.upstream_servers resolved={@resolved} />
          <.query_log_table entries={@query_log} />
        <% else %>
          <.no_resolved_data />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp resolved_overview(assigns) do
    ~H"""
    <div class="grid grid-cols-2 sm:grid-cols-4 gap-4">
      <.stat
        title="Listen Address"
        value={@resolved["listen"] || "—"}
        desc={"Port #{@resolved["port"] || "—"}"}
      />
      <.stat
        title="Total Queries"
        value={format_number(@resolved["counters"]["total"])}
        desc="since start"
      />
      <.stat
        title="Cache"
        value={if @resolved["cache_enabled"], do: "Enabled", else: "Disabled"}
        desc={
          if @resolved["cache_enabled"],
            do: "#{format_number(@resolved["counters"]["cached"])} hits",
            else: ""
        }
      />
      <.stat
        title="Upstreams"
        value={length(@resolved["upstreams"] || [])}
        desc="configured servers"
      />
    </div>
    """
  end

  defp upstream_servers(assigns) do
    upstreams = assigns.resolved["upstreams"] || []
    assigns = assign(assigns, :upstreams, upstreams)

    ~H"""
    <.card title="Upstream DNS Servers">
      <%= if @upstreams == [] do %>
        <p class="text-on-surface-variant py-4">No upstream servers configured</p>
      <% else %>
        <div class="flex flex-wrap gap-2">
          <%= for upstream <- @upstreams do %>
            <span class="px-3 py-1.5 bg-surface-container rounded-lg font-mono text-sm">
              {upstream}
            </span>
          <% end %>
        </div>
      <% end %>
    </.card>
    """
  end

  defp query_log_table(assigns) do
    ~H"""
    <.card title="Query Log">
      <:actions>
        <span class="text-sm text-on-surface-variant">{length(@entries)} entries</span>
      </:actions>
      <%= if @entries == [] do %>
        <div class="text-center py-8 text-on-surface-variant">
          <.dm_mdi name="text-box-search-outline" class="h-10 w-10 mx-auto mb-2" />
          <p>No queries recorded yet</p>
        </div>
      <% else %>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Time</th>
                <th>Domain</th>
                <th>Type</th>
                <th>Source</th>
                <th>Duration</th>
              </tr>
            </thead>
            <tbody>
              <%= for entry <- @entries do %>
                <tr>
                  <td class="text-xs text-on-surface-variant whitespace-nowrap">
                    {format_timestamp(entry["timestamp"])}
                  </td>
                  <td class="font-mono text-sm max-w-xs truncate">{entry["domain"]}</td>
                  <td>
                    <.badge color="ghost" size="sm">{entry["type"]}</.badge>
                  </td>
                  <td>
                    <.badge color={source_color(entry["source"])} size="sm">
                      {entry["source"]}
                    </.badge>
                  </td>
                  <td class="text-xs font-mono text-on-surface-variant">
                    {format_duration(entry["duration_us"])}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </.card>
    """
  end

  defp no_resolved_data(assigns) do
    ~H"""
    <div class="card bg-surface shadow-xl">
      <div class="card-body text-center py-12">
        <.dm_mdi name="dns" class="h-12 w-12 mx-auto mb-3 text-on-surface-variant" />
        <p class="text-on-surface-variant">No resolved server data reported by this node</p>
        <p class="text-sm text-on-surface-variant mt-1">
          The resolved service may not be running on this Netman instance
        </p>
      </div>
    </div>
    """
  end

  defp source_color("forward"), do: "primary"
  defp source_color("cache"), do: "success"
  defp source_color("intercept"), do: "info"
  defp source_color("error"), do: "error"
  defp source_color(_), do: "ghost"

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S.") <> milliseconds(dt)
      _ -> iso_string
    end
  end

  defp format_timestamp(_), do: "—"

  defp milliseconds(%DateTime{microsecond: {us, _}}),
    do: us |> div(1000) |> Integer.to_string() |> String.pad_leading(3, "0")

  defp format_duration(nil), do: "—"

  defp format_duration(us) when is_number(us) and us >= 1000,
    do: "#{Float.round(us / 1000, 1)}ms"

  defp format_duration(us) when is_number(us), do: "#{us}µs"
  defp format_duration(_), do: "—"

  # Real-time query log entry from channel
  @impl true
  def handle_info({:query_log_entry, entry}, socket) do
    query_log = [entry | socket.assigns.query_log] |> Enum.take(@max_log_entries)
    {:noreply, assign(socket, :query_log, query_log)}
  end

  # Status updates from registry
  def handle_info({event, %{node_id: node_id}}, socket)
      when event in [:netman_joined, :netman_updated] and node_id == socket.assigns.node_id do
    case NetmanRegistry.get(node_id) do
      {:ok, client} ->
        resolved = client[:resolved]
        # Keep streaming query_log — don't replace with status snapshot
        {:noreply, assign(socket, client: client, resolved: resolved)}

      :error ->
        {:noreply, push_navigate(socket, to: "/netman")}
    end
  end

  def handle_info({:netman_left, %{node_id: node_id}}, socket)
      when node_id == socket.assigns.node_id do
    {:noreply,
     socket
     |> put_flash(:info, "Node disconnected")
     |> push_navigate(to: "/netman")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
