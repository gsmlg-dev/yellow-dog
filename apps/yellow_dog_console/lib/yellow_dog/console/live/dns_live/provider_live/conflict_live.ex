defmodule YellowDog.Console.DnsLive.ProviderLive.ConflictLive do
  @moduledoc """
  Conflict resolution page for DNS providers using the `:manual`
  strategy. Shows unresolved conflicts with side-by-side local vs
  remote record comparisons and resolution controls.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.ServiceHelper, only: [safe_call: 3]

  alias YellowDog.Console.DnsLive.ProviderLive.Index, as: ProviderIndex

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns_provider:sync")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns_provider:config")
    end

    {:ok,
     socket
     |> assign(:provider_name, name)
     |> assign(:page_title, "Conflicts: #{name}")
     |> assign_conflicts()}
  end

  # ------------------------------------------------------------------
  # Events
  # ------------------------------------------------------------------

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_conflicts(socket)}
  end

  def handle_event("keep_local", %{"id" => conflict_id}, socket) do
    name = socket.assigns.provider_name

    safe_call(
      YellowDog.DnsProvider,
      fn -> YellowDog.DnsProvider.resolve_conflict(name, conflict_id, :keep_local) end,
      :ok
    )

    {:noreply,
     socket
     |> put_flash(:info, "Conflict resolved: kept local records")
     |> assign_conflicts()}
  end

  def handle_event("keep_remote", %{"id" => conflict_id}, socket) do
    name = socket.assigns.provider_name

    safe_call(
      YellowDog.DnsProvider,
      fn -> YellowDog.DnsProvider.resolve_conflict(name, conflict_id, :keep_remote) end,
      :ok
    )

    {:noreply,
     socket
     |> put_flash(:info, "Conflict resolved: kept remote records")
     |> assign_conflicts()}
  end

  def handle_event("resolve_all_local", _params, socket) do
    name = socket.assigns.provider_name

    safe_call(
      YellowDog.DnsProvider,
      fn -> YellowDog.DnsProvider.resolve_all_conflicts(name, :keep_local) end,
      :ok
    )

    {:noreply,
     socket
     |> put_flash(:info, "All conflicts resolved: kept local records")
     |> assign_conflicts()}
  end

  def handle_event("resolve_all_remote", _params, socket) do
    name = socket.assigns.provider_name

    safe_call(
      YellowDog.DnsProvider,
      fn -> YellowDog.DnsProvider.resolve_all_conflicts(name, :keep_remote) end,
      :ok
    )

    {:noreply,
     socket
     |> put_flash(:info, "All conflicts resolved: kept remote records")
     |> assign_conflicts()}
  end

  # ------------------------------------------------------------------
  # PubSub
  # ------------------------------------------------------------------

  @impl true
  def handle_info({:dns_provider, _event}, socket) do
    {:noreply, assign_conflicts(socket)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ------------------------------------------------------------------
  # Data loading
  # ------------------------------------------------------------------

  defp assign_conflicts(socket) do
    name = socket.assigns.provider_name

    conflicts =
      safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.list_conflicts(name) end, [])

    assign(socket, :conflicts, conflicts)
  end

  # ------------------------------------------------------------------
  # Template helpers
  # ------------------------------------------------------------------

  @doc false
  def format_records(nil), do: "-"
  def format_records([]), do: "-"

  def format_records(records) when is_list(records) do
    Enum.map_join(records, "\n", fn r ->
      rdata = Map.get(r, :rdata, Map.get(r, "rdata", ""))
      ttl = Map.get(r, :ttl, Map.get(r, "ttl", ""))
      "#{rdata} (TTL: #{ttl})"
    end)
  end

  def format_records(_), do: "-"

  @doc false
  def format_detected_at(nil), do: "Unknown"

  def format_detected_at(unix) when is_integer(unix) do
    ProviderIndex.format_sync_time(unix)
  end

  def format_detected_at(_), do: "Unknown"
end
