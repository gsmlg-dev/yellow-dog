defmodule YellowDog.Console.Dhcpv6Live.LeasesLive do
  @moduledoc """
  LiveView for DHCPv6 lease management.

  Displays all active IA_NA (address) and IA_PD (prefix) bindings with
  filtering by DUID, IA type, state, and pool. Shows preferred/valid
  lifetimes and supports real-time updates via telemetry subscriptions.
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
        "dhcpv6-leases-#{inspect(self())}",
        [:yellow_dog, :dhcpv6, :lease_allocated],
        &handle_telemetry_event/4,
        %{pid: self()}
      )
    end

    {:ok,
     socket
     |> assign(
       page_title: "DHCPv6 Leases",
       service_running: service_running?(YellowDog.Dhcpv6.LeaseManager),
       search_query: "",
       filter_state: "all",
       filter_ia_type: "all",
       filter_pool: "all"
     )
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
  def handle_event("filter_ia_type", %{"ia_type" => ia_type}, socket) do
    {:noreply,
     socket
     |> assign(:filter_ia_type, ia_type)
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
  def handle_event("release_lease", %{"duid" => duid_str, "iaid" => iaid_str}, socket) do
    with {iaid, ""} <- Integer.parse(iaid_str),
         duid_binary <- parse_duid_string(duid_str) do
      case YellowDog.Dhcpv6.release_lease(duid_binary, iaid) do
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
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid DUID or IAID format")}
    end
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    leases = socket.assigns.filtered_leases
    csv = build_csv(leases)
    filename = "dhcpv6_leases_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"

    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_info({:telemetry_event, _event, _measurements, _metadata}, socket) do
    {:noreply, load_leases(socket)}
  end

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach("dhcpv6-leases-#{inspect(self())}")
    :ok
  end

  # Private Functions

  defp load_leases(socket) do
    leases = get_leases()
    pools = get_pools()

    filtered_leases =
      leases
      |> filter_by_search(socket.assigns.search_query)
      |> filter_by_state(socket.assigns.filter_state)
      |> filter_by_ia_type(socket.assigns.filter_ia_type)
      |> filter_by_pool(socket.assigns.filter_pool)

    socket
    |> assign(:leases, filtered_leases)
    |> assign(:pools, pools)
  end

  defp get_leases do
    safe_call(YellowDog.Dhcpv6, fn -> YellowDog.Dhcpv6.list_leases() end, [])
  end

  defp get_pools do
    safe_call(
      YellowDog.Dhcpv6.LeaseManager,
      fn ->
        YellowDog.Dhcpv6.LeaseManager.get_pools()
        |> Enum.map(& &1.name)
        |> Enum.sort()
      end,
      []
    )
  end

  defp filter_by_search(leases, ""), do: leases

  defp filter_by_search(leases, query) do
    query_lower = String.downcase(query)

    Enum.filter(leases, fn lease ->
      duid_str = format_duid(lease.duid) |> String.downcase()

      ip_str =
        if(lease.ia_type == :ia_pd,
          do: format_prefix(lease.delegated_prefix),
          else: format_ipv6(lease.ip_address)
        )
        |> String.downcase()

      hostname_str = (lease[:hostname] || "") |> String.downcase()

      String.contains?(duid_str, query_lower) or
        String.contains?(ip_str, query_lower) or
        String.contains?(hostname_str, query_lower)
    end)
  end

  defp filter_by_state(leases, "all"), do: leases

  defp filter_by_state(leases, state),
    do: Enum.filter(leases, fn l -> to_string(l.state) == state end)

  defp filter_by_ia_type(leases, "all"), do: leases

  defp filter_by_ia_type(leases, ia_type),
    do: Enum.filter(leases, fn l -> to_string(l.ia_type) == ia_type end)

  defp filter_by_pool(leases, "all"), do: leases
  defp filter_by_pool(leases, pool), do: Enum.filter(leases, fn l -> l.pool_name == pool end)

  defp handle_telemetry_event(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp build_csv(leases) do
    header =
      "DUID,IAID,IA Type,IPv6 Address/Prefix,State,Pool,Preferred Lifetime,Valid Lifetime,Allocated At\r\n"

    rows =
      Enum.map_join(leases, "\r\n", fn lease ->
        [
          csv_escape(format_duid(lease.duid)),
          csv_escape(to_string(lease.iaid)),
          csv_escape(to_string(lease.ia_type)),
          csv_escape(format_ipv6_or_prefix(lease)),
          csv_escape(to_string(lease.state)),
          csv_escape(lease.pool_name || ""),
          csv_escape(format_duration(lease.preferred_lifetime)),
          csv_escape(format_duration(lease.valid_lifetime)),
          csv_escape(format_expiration(lease.allocated_at))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

  defp format_ipv6_or_prefix(%{ia_type: :ia_na, ipv6_address: addr}) when addr != nil do
    format_ipv6(addr)
  end

  defp format_ipv6_or_prefix(%{ia_type: :ia_pd, prefix: prefix, prefix_length: len})
       when prefix != nil and len != nil do
    "#{format_ipv6(prefix)}/#{len}"
  end

  defp format_ipv6_or_prefix(_), do: "N/A"


end
