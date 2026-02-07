defmodule YellowDog.Console.Dhcpv4Live.LeasesLive do
  @moduledoc """
  LiveView for DHCPv4 lease management.

  Displays all active and expired leases with filtering by MAC address,
  state (bound/offered/expired), and pool. Supports real-time updates
  via telemetry subscriptions and allows lease release operations.
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.FormatHelper
  import YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to lease events
      :telemetry.attach(
        "dhcpv4-leases-#{inspect(self())}",
        [:yellow_dog, :dhcpv4, :lease_allocated],
        &handle_telemetry_event/4,
        %{pid: self()}
      )
    end

    {:ok,
     socket
     |> assign(:page_title, "DHCP Leases")
     |> assign(:service_running, dhcpv4_service_running?())
     |> assign(:search_query, "")
     |> assign(:filter_state, "all")
     |> assign(:filter_pool, "all")
     |> load_leases()}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> load_leases()}
  end

  @impl true
  def handle_event("filter_state", %{"state" => state}, socket) do
    {:noreply,
     socket
     |> assign(:filter_state, state)
     |> load_leases()}
  end

  @impl true
  def handle_event("filter_pool", %{"pool" => pool}, socket) do
    {:noreply,
     socket
     |> assign(:filter_pool, pool)
     |> load_leases()}
  end

  @impl true
  def handle_event("release_lease", %{"mac" => mac}, socket) do
    mac_binary = parse_mac_string(mac)

    case YellowDog.Dhcpv4.release_lease(mac_binary) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Lease released successfully")
         |> load_leases()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to release lease: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    leases = socket.assigns.filtered_leases
    csv = build_csv(leases)
    filename = "dhcpv4_leases_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"

    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_info({:telemetry_event, _event, _measurements, _metadata}, socket) do
    {:noreply, load_leases(socket)}
  end

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach("dhcpv4-leases-#{inspect(self())}")
    :ok
  end

  # Private Functions

  defp load_leases(socket) do
    all_leases = get_all_leases()
    pools = get_unique_pools(all_leases)
    filtered = filter_leases(all_leases, socket.assigns)

    socket
    |> assign(:all_leases, all_leases)
    |> assign(:filtered_leases, filtered)
    |> assign(:pools, pools)
  end

  defp get_all_leases do
    safe_call(YellowDog.Dhcpv4, fn -> YellowDog.Dhcpv4.list_leases() end, [])
  end

  defp get_unique_pools(leases) do
    leases
    |> Enum.map(& &1.pool_name)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp filter_leases(leases, %{search_query: query, filter_state: state, filter_pool: pool}) do
    leases
    |> filter_by_search(query)
    |> filter_by_state(state)
    |> filter_by_pool(pool)
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  defp filter_by_search(leases, ""), do: leases

  defp filter_by_search(leases, query) do
    query_lower = String.downcase(query)

    Enum.filter(leases, fn lease ->
      mac_match =
        format_mac(lease.mac_address) |> String.downcase() |> String.contains?(query_lower)

      ip_match = format_ip(lease.ip_address) |> String.contains?(query_lower)

      hostname_match =
        if lease.hostname,
          do: String.downcase(lease.hostname) |> String.contains?(query_lower),
          else: false

      mac_match || ip_match || hostname_match
    end)
  end

  defp filter_by_state(leases, "all"), do: leases

  defp filter_by_state(leases, state) do
    state_atom = String.to_existing_atom(state)
    Enum.filter(leases, &(&1.state == state_atom))
  rescue
    _ -> leases
  end

  defp filter_by_pool(leases, "all"), do: leases
  defp filter_by_pool(leases, pool), do: Enum.filter(leases, &(&1.pool_name == pool))

  defp count_by_state(leases, state) do
    Enum.count(leases, &(&1.state == state))
  end

  defp handle_telemetry_event(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp build_csv(leases) do
    header =
      "MAC Address,IP Address,Hostname,State,Pool,Allocated At,Expires At,Time Remaining\r\n"

    rows =
      Enum.map_join(leases, "\r\n", fn lease ->
        [
          csv_escape(format_mac(lease.mac_address)),
          csv_escape(format_ip(lease.ip_address)),
          csv_escape(lease.hostname || ""),
          csv_escape(to_string(lease.state)),
          csv_escape(lease.pool_name || ""),
          csv_escape(format_expiration(lease.allocated_at)),
          csv_escape(format_expiration(lease.expires_at)),
          csv_escape(format_time_remaining(lease.expires_at))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

  defp dhcpv4_service_running?, do: Process.whereis(YellowDog.Dhcpv4.LeaseManager) != nil
end
