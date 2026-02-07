defmodule YellowDog.Console.Dhcpv6Live.PoolLive do
  @moduledoc """
  LiveView for individual DHCPv6 pool details.

  Shows pool configuration (prefix ranges, lifetimes, DNS servers),
  utilization statistics, static DUID-to-address bindings, and all
  IA bindings within the pool.
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.FormatHelper

  @impl true
  def mount(%{"pool_name" => pool_name}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "DHCPv6 Pool: #{pool_name}")
     |> assign(:pool_name, pool_name)
     |> load_pool_data()}
  end

  # Private Functions

  defp load_pool_data(socket) do
    pool_name = socket.assigns.pool_name
    pool_stats = get_pool_stats(pool_name)
    pool_config = get_pool_config(pool_name)
    leases = get_pool_leases(pool_name)

    socket
    |> assign(:pool_stats, pool_stats)
    |> assign(:pool_config, pool_config)
    |> assign(:leases, leases)
  end

  defp get_pool_stats(pool_name) do
    case Code.ensure_loaded?(YellowDog.Dhcpv6) do
      true ->
        try do
          stats = YellowDog.Dhcpv6.get_all_pool_stats()
          Map.get(stats, pool_name)
        rescue
          _ -> nil
        catch
          :exit, _ -> nil
        end

      false ->
        nil
    end
  end

  defp get_pool_config(pool_name) do
    case Code.ensure_loaded?(YellowDog.Dhcpv6.LeaseManager) do
      true ->
        try do
          pools = YellowDog.Dhcpv6.LeaseManager.get_pools()
          Enum.find(pools, fn p -> p.name == pool_name end)
        rescue
          _ -> nil
        catch
          :exit, _ -> nil
        end

      false ->
        nil
    end
  end

  defp get_pool_leases(pool_name) do
    case Code.ensure_loaded?(YellowDog.Dhcpv6) do
      true ->
        try do
          YellowDog.Dhcpv6.list_leases()
          |> Enum.filter(fn l -> l.pool_name == pool_name end)
          |> Enum.sort_by(& &1.expires_at, :desc)
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end

      false ->
        []
    end
  end

  defp format_duid_short(duid) when is_binary(duid) do
    formatted = format_duid(duid)

    if String.length(formatted) > 20 do
      String.slice(formatted, 0, 17) <> "..."
    else
      formatted
    end
  end
end
