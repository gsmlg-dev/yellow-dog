defmodule YellowDog.Console.Dhcpv6Live.PoolLive do
  @moduledoc """
  LiveView for individual DHCPv6 pool details.

  Shows pool configuration (prefix ranges, lifetimes, DNS servers),
  utilization statistics, static DUID-to-address bindings, and all
  IA bindings within the pool.
  """

  use YellowDog.Console, :live_view

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

  defp format_duid(duid) when is_binary(duid) do
    duid
    |> :binary.bin_to_list()
    |> Enum.map(fn b -> b |> Integer.to_string(16) |> String.pad_leading(2, "0") end)
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_duid(_), do: "Unknown"

  defp format_ipv6({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map(fn b -> b |> Integer.to_string(16) |> String.downcase() end)
    |> Enum.join(":")
  end

  defp format_ipv6(_), do: "Unknown"

  defp format_prefix({{a, b, c, d, e, f, g, h}, len}) do
    "#{format_ipv6({a, b, c, d, e, f, g, h})}/#{len}"
  end

  defp format_prefix(_), do: "Unknown"

  defp format_lifetime(seconds) when is_integer(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86400)}d"
    end
  end

  defp format_lifetime(_), do: "N/A"

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

  defp format_ia_type(:ia_na), do: "IA_NA"
  defp format_ia_type(:ia_ta), do: "IA_TA"
  defp format_ia_type(:ia_pd), do: "IA_PD"
  defp format_ia_type(type), do: to_string(type)

  defp get_utilization_color(percent) when percent >= 90, do: "error"
  defp get_utilization_color(percent) when percent >= 75, do: "warning"
  defp get_utilization_color(percent) when percent >= 50, do: "info"
  defp get_utilization_color(_), do: "success"

  defp get_utilization_text_color(percent) when percent >= 90, do: "text-error"
  defp get_utilization_text_color(percent) when percent >= 75, do: "text-warning"
  defp get_utilization_text_color(percent) when percent >= 50, do: "text-info"
  defp get_utilization_text_color(_), do: "text-success"

  defp get_ia_type_color(:ia_na), do: "primary"
  defp get_ia_type_color(:ia_ta), do: "secondary"
  defp get_ia_type_color(:ia_pd), do: "accent"
  defp get_ia_type_color(_), do: "ghost"

  defp get_state_text_color(:active), do: "text-success"
  defp get_state_text_color(:offered), do: "text-info"
  defp get_state_text_color(:released), do: "text-warning"
  defp get_state_text_color(:expired), do: "text-error"
  defp get_state_text_color(:declined), do: "text-error"
  defp get_state_text_color(_), do: "text-base-content"
end
