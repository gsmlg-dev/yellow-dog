defmodule YellowDog.Console.Dhcpv6Live.LeasesLive do
  @moduledoc """
  LiveView for DHCPv6 lease management.

  Displays all active IA_NA (address) and IA_PD (prefix) bindings with
  filtering by DUID, IA type, state, and pool. Shows preferred/valid
  lifetimes and supports real-time updates via telemetry subscriptions.
  """

  use YellowDog.Console, :live_view

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
     |> assign(:page_title, "DHCPv6 Leases")
     |> assign(:search_query, "")
     |> assign(:filter_state, "all")
     |> assign(:filter_ia_type, "all")
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
    case Code.ensure_loaded?(YellowDog.Dhcpv6) do
      true ->
        try do
          YellowDog.Dhcpv6.list_leases()
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end

      false ->
        []
    end
  end

  defp get_pools do
    case Code.ensure_loaded?(YellowDog.Dhcpv6.LeaseManager) do
      true ->
        try do
          YellowDog.Dhcpv6.LeaseManager.get_pools()
          |> Enum.map(& &1.name)
          |> Enum.sort()
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end

      false ->
        []
    end
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

  defp format_duid(duid) when is_binary(duid) do
    duid
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_duid(_), do: "Unknown"

  defp parse_duid_string(duid_str) do
    duid_str
    |> String.split(":")
    |> Enum.map(&String.to_integer(&1, 16))
    |> :binary.list_to_bin()
  end

  defp format_ipv6({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.downcase/1)
    |> Enum.join(":")
  end

  defp format_ipv6(_), do: "Unknown"

  defp format_prefix({{a, b, c, d, e, f, g, h}, len}) do
    "#{format_ipv6({a, b, c, d, e, f, g, h})}/#{len}"
  end

  defp format_prefix(_), do: "Unknown"

  defp format_ia_type(:ia_na), do: "IA_NA"
  defp format_ia_type(:ia_ta), do: "IA_TA"
  defp format_ia_type(:ia_pd), do: "IA_PD"
  defp format_ia_type(type), do: to_string(type)

  defp format_expires(expires_at) when is_integer(expires_at) do
    now = System.system_time(:second)
    remaining = expires_at - now

    cond do
      remaining < 0 -> "Expired"
      remaining < 60 -> "#{remaining}s"
      remaining < 3600 -> "#{div(remaining, 60)}m"
      remaining < 86400 -> "#{div(remaining, 3600)}h"
      true -> "#{div(remaining, 86400)}d"
    end
  end

  defp format_expires(_), do: "N/A"

  defp get_ia_type_color(:ia_na), do: "primary"
  defp get_ia_type_color(:ia_ta), do: "secondary"
  defp get_ia_type_color(:ia_pd), do: "accent"
  defp get_ia_type_color(_), do: "ghost"

  defp get_state_color(:active), do: "success"
  defp get_state_color(:offered), do: "info"
  defp get_state_color(:released), do: "warning"
  defp get_state_color(:expired), do: "error"
  defp get_state_color(:declined), do: "error"
  defp get_state_color(_), do: "ghost"
end
