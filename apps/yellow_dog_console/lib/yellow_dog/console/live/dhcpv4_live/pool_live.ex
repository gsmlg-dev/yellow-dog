defmodule YellowDog.Console.Dhcpv4Live.PoolLive do
  @moduledoc """
  LiveView for individual DHCPv4 pool details.

  Shows pool configuration (subnet, ranges, gateway, DNS), utilization
  statistics, static reservations, and all leases within the pool.
  Supports filtering and search within the pool's lease list.
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.FormatHelper

  @impl true
  def mount(%{"pool_name" => pool_name}, _session, socket) do
    if connected?(socket) do
      # Subscribe to lease events for this pool
      :telemetry.attach(
        "dhcpv4-pool-#{pool_name}-#{inspect(self())}",
        [:yellow_dog, :dhcpv4, :lease_allocated],
        &handle_telemetry_event/4,
        %{pid: self(), pool_name: pool_name}
      )
    end

    {:ok,
     socket
     |> assign(:pool_name, pool_name)
     |> assign(:page_title, "Pool: #{pool_name}")
     |> assign(:search_query, "")
     |> assign(:filter_state, "all")
     |> load_pool_data()}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> load_pool_data()}
  end

  @impl true
  def handle_event("filter_state", %{"state" => state}, socket) do
    {:noreply,
     socket
     |> assign(:filter_state, state)
     |> load_pool_data()}
  end

  @impl true
  def handle_event("release_lease", %{"mac" => mac}, socket) do
    mac_binary = parse_mac_string(mac)

    case YellowDog.Dhcpv4.release_lease(mac_binary) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Lease released successfully")
         |> load_pool_data()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to release lease: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:telemetry_event, _event, _measurements, metadata}, socket) do
    # Only reload if event is for this pool
    if metadata[:pool_name] == socket.assigns.pool_name do
      {:noreply, load_pool_data(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    :telemetry.detach("dhcpv4-pool-#{socket.assigns.pool_name}-#{inspect(self())}")
    :ok
  end

  # Private Functions

  defp load_pool_data(socket) do
    pool_name = socket.assigns.pool_name

    # Get pool configuration and statistics
    pool_config = get_pool_config(pool_name)
    pool_stats = get_pool_stats(pool_name)
    static_reservations = get_static_reservations(pool_name)

    # Get all leases for this pool
    all_leases = get_pool_leases(pool_name)

    # Filter leases based on search query and state
    filtered =
      all_leases
      |> filter_by_search(socket.assigns.search_query)
      |> filter_by_state(socket.assigns.filter_state)
      |> Enum.sort_by(& &1.updated_at, :desc)

    socket
    |> assign(:pool_config, pool_config)
    |> assign(:pool_stats, pool_stats)
    |> assign(:static_reservations, static_reservations)
    |> assign(:all_leases, all_leases)
    |> assign(:filtered_leases, filtered)
  end

  defp get_pool_config(pool_name) do
    case Code.ensure_loaded?(YellowDog.Dhcpv4.LeaseManager) do
      true ->
        try do
          case YellowDog.Dhcpv4.LeaseManager.get_pool_config(pool_name) do
            {:ok, config} -> config
            _ -> default_pool_config(pool_name)
          end
        rescue
          _ -> default_pool_config(pool_name)
        catch
          :exit, _ -> default_pool_config(pool_name)
        end

      false ->
        default_pool_config(pool_name)
    end
  end

  defp default_pool_config(pool_name) do
    %{
      name: pool_name,
      range_start: {192, 168, 1, 10},
      range_end: {192, 168, 1, 254},
      subnet_mask: {255, 255, 255, 0},
      gateway: {192, 168, 1, 1},
      dns_servers: [{8, 8, 8, 8}, {8, 8, 4, 4}],
      domain_name: "local",
      lease_time: 86400,
      excluded_ranges: []
    }
  end

  defp get_pool_stats(pool_name) do
    case Code.ensure_loaded?(YellowDog.Dhcpv4) do
      true ->
        try do
          case YellowDog.Dhcpv4.get_pool_stats(pool_name) do
            {:ok, stats} -> stats
            _ -> default_pool_stats()
          end
        rescue
          _ -> default_pool_stats()
        catch
          :exit, _ -> default_pool_stats()
        end

      false ->
        default_pool_stats()
    end
  end

  defp default_pool_stats do
    %{
      total_addresses: 0,
      allocated_addresses: 0,
      available_addresses: 0,
      static_reservations: 0,
      utilization_percent: 0.0,
      leases_by_state: %{}
    }
  end

  defp get_static_reservations(pool_name) do
    case Code.ensure_loaded?(YellowDog.Dhcpv4.LeaseManager) do
      true ->
        try do
          YellowDog.Dhcpv4.LeaseManager.get_static_reservations(pool_name)
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end

      false ->
        []
    end
  end

  defp get_pool_leases(pool_name) do
    case Code.ensure_loaded?(YellowDog.Dhcpv4) do
      true ->
        try do
          YellowDog.Dhcpv4.list_leases()
          |> Enum.filter(&(&1.pool_name == pool_name))
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

  @valid_lease_states ~w(active offered released expired declined)

  defp filter_by_state(leases, state) when state in @valid_lease_states do
    state_atom = String.to_existing_atom(state)
    Enum.filter(leases, &(&1.state == state_atom))
  end

  defp filter_by_state(leases, _state), do: leases

  defp handle_telemetry_event(event, measurements, metadata, %{pid: pid, pool_name: pool_name}) do
    if metadata[:pool_name] == pool_name do
      send(pid, {:telemetry_event, event, measurements, metadata})
    end
  end
end
