defmodule YellowDog.Console.Dhcpv4Live.PoolsLive do
  @moduledoc """
  LiveView for managing DHCPv4 address pools.

  Provides CRUD operations for address pools:
  - List all pools with utilization stats
  - Add new pools
  - Edit existing pools
  - Delete pools (with confirmation)
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper

  import YellowDog.Console.FormatHelper,
    only: [format_ip: 1, format_dns_servers: 1, format_duration: 1, filtered_pools: 2]

  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Components.PoolFormComponent
  alias YellowDog.Console.Settings.AddressPool

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Address Pools",
       show_form: false,
       form_mode: :create,
       editing_pool: nil,
       filter: "",
       service_running: service_running?(YellowDog.Dhcpv4.LeaseManager)
     )
     |> load_pools()}
  end

  @impl true
  def handle_event("show_new_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:form_mode, :create)
     |> assign(:editing_pool, nil)}
  end

  @impl true
  def handle_event("show_edit_form", %{"pool-name" => pool_name}, socket) do
    pool = find_pool(socket.assigns.pools, pool_name)

    if pool do
      # Convert backend pool to AddressPool struct for the form
      address_pool = %AddressPool{
        id: pool_name,
        name: pool_name,
        protocol: :ipv4,
        network: pool[:network],
        range_start: format_ip(pool.range_start),
        range_end: format_ip(pool.range_end),
        lease_time: pool.lease_time,
        gateway: format_ip(pool[:gateway]),
        dns_servers: format_dns_servers(pool[:dns_servers])
      }

      {:noreply,
       socket
       |> assign(:show_form, true)
       |> assign(:form_mode, :edit)
       |> assign(:editing_pool, address_pool)}
    else
      {:noreply, put_flash(socket, :error, "Pool not found")}
    end
  end

  @impl true
  def handle_event("delete_pool", %{"pool-name" => pool_name}, socket) do
    case YellowDog.Dhcpv4.remove_pool(pool_name, force: false) do
      :ok ->
        {:noreply,
         socket
         |> load_pools()
         |> put_flash(:info, "Pool '#{pool_name}' deleted successfully")}

      {:error, :has_active_leases} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Cannot delete pool '#{pool_name}': has active leases. Release leases first or use force delete."
         )}

      {:error, :pool_not_found} ->
        {:noreply, put_flash(socket, :error, "Pool '#{pool_name}' not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete pool: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("force_delete_pool", %{"pool-name" => pool_name}, socket) do
    case YellowDog.Dhcpv4.remove_pool(pool_name, force: true) do
      :ok ->
        {:noreply,
         socket
         |> load_pools()
         |> put_flash(:info, "Pool '#{pool_name}' force deleted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete pool: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    pools = filtered_pools(socket.assigns.pools, socket.assigns.filter)
    csv = build_pools_csv(pools)

    {:noreply,
     push_event(socket, "download_csv", %{
       content: csv,
       filename: "dhcpv4_pools_#{Date.to_iso8601(Date.utc_today())}.csv"
     })}
  end

  @impl true
  def handle_info(:close_pool_form, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_pool, nil)}
  end

  @impl true
  def handle_info({:pool_saved, :dhcpv4, pool, mode}, socket) do
    result =
      try do
        case mode do
          :create ->
            pool_config = build_pool_config(pool)
            YellowDog.Dhcpv4.add_pool(pool_config)

          :edit ->
            pool_config = build_pool_config(pool)
            YellowDog.Dhcpv4.update_pool(pool.name, pool_config)
        end
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, "Service unavailable: #{inspect(reason)}"}
      end

    case result do
      {:ok, _} ->
        flash_msg =
          if mode == :create, do: "Pool created successfully", else: "Pool updated successfully"

        {:noreply,
         socket
         |> assign(:show_form, false)
         |> assign(:editing_pool, nil)
         |> load_pools()
         |> put_flash(:info, flash_msg)}

      {:error, :pool_already_exists} ->
        {:noreply, put_flash(socket, :error, "A pool with this name already exists")}

      {:error, :range_overlap} ->
        {:noreply, put_flash(socket, :error, "IP range overlaps with an existing pool")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save pool: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <!-- Header -->
        <div class="flex justify-between items-center">
          <div>
            <h1 class="text-2xl font-bold">DHCPv4 Address Pools</h1>
            <p class="text-base-content/70">Manage IPv4 address pools for DHCP allocation</p>
          </div>
          <button class="btn btn-primary" phx-click="show_new_form">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="w-5 h-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 4v16m8-8H4"
              />
            </svg>
            Add Pool
          </button>
        </div>
        
    <!-- Filter Bar -->
        <div class="flex flex-wrap gap-4 items-center">
          <div class="flex-1 min-w-[200px]">
            <input
              type="text"
              placeholder="Search pools..."
              aria-label="Search DHCPv4 pools"
              value={@filter}
              phx-change="filter"
              phx-debounce="300"
              name="filter"
              class="input input-bordered w-full"
            />
          </div>
          <button
            class="btn btn-outline btn-sm"
            phx-click="export_csv"
            id="export-csv"
            phx-hook="CsvDownload"
          >
            Export CSV
          </button>
        </div>
        
    <!-- Service Status Alert -->
        <%= unless @service_running do %>
          <div class="alert alert-info">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="w-6 h-6 shrink-0 stroke-current"
              fill="none"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
            <div>
              <h3 class="font-bold">DHCPv4 Service Not Running</h3>
              <div class="text-sm">
                Pool configuration can still be managed. Pool statistics will be unavailable until the service is started.
              </div>
            </div>
          </div>
        <% end %>
        
    <!-- Pools Table -->
        <%= if Enum.empty?(@pools) do %>
          <div class="card bg-base-200">
            <div class="card-body items-center text-center py-12">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="w-16 h-16 text-base-content/30"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01"
                />
              </svg>
              <h2 class="card-title text-base-content/70">No Address Pools</h2>
              <p class="text-base-content/50">
                Create your first address pool to start allocating IP addresses
              </p>
              <button class="btn btn-primary mt-4" phx-click="show_new_form">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="w-5 h-5"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M12 4v16m8-8H4"
                  />
                </svg>
                Add Pool
              </button>
            </div>
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th scope="col">Name</th>
                  <th scope="col">Network</th>
                  <th scope="col">IP Range</th>
                  <th scope="col">Lease Time</th>
                  <th scope="col">Gateway</th>
                  <th scope="col">Utilization</th>
                  <th scope="col">Status</th>
                  <th scope="col">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for pool <- filtered_pools(@pools, @filter) do %>
                  <tr>
                    <td class="font-medium">
                      <.link navigate={~p"/dhcpv4/pools/#{pool.name}"} class="link link-primary">
                        {pool.name}
                      </.link>
                    </td>
                    <td class="font-mono text-sm">{pool[:network] || "-"}</td>
                    <td class="font-mono text-sm">
                      {format_ip(pool.range_start)} - {format_ip(pool.range_end)}
                    </td>
                    <td>{format_duration(pool.lease_time)}</td>
                    <td class="font-mono text-sm">{format_ip(pool[:gateway]) || "-"}</td>
                    <td>
                      <% stats = get_pool_stats(pool.name) %>
                      <div class="flex items-center gap-2">
                        <progress
                          class={"progress w-20 progress-#{utilization_color(stats.utilization_percent)}"}
                          value={stats.utilization_percent}
                          max="100"
                        />
                        <span class="text-sm">{Float.round(stats.utilization_percent, 1)}%</span>
                      </div>
                      <span class="text-xs text-base-content/50">
                        {stats.allocated_addresses}/{stats.total_addresses} allocated
                      </span>
                    </td>
                    <td>
                      <%= if pool[:enabled] != false do %>
                        <span class="badge badge-success badge-sm">Active</span>
                      <% else %>
                        <span class="badge badge-ghost badge-sm">Disabled</span>
                      <% end %>
                    </td>
                    <td>
                      <div class="flex gap-1">
                        <button
                          class="btn btn-ghost btn-sm"
                          phx-click="show_edit_form"
                          phx-value-pool-name={pool.name}
                          title="Edit pool"
                        >
                          <svg
                            xmlns="http://www.w3.org/2000/svg"
                            class="w-4 h-4"
                            fill="none"
                            viewBox="0 0 24 24"
                            stroke="currentColor"
                          >
                            <path
                              stroke-linecap="round"
                              stroke-linejoin="round"
                              stroke-width="2"
                              d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
                            />
                          </svg>
                        </button>
                        <button
                          class="btn btn-ghost btn-sm text-error"
                          phx-click="delete_pool"
                          phx-value-pool-name={pool.name}
                          phx-disable-with="..."
                          data-confirm="Are you sure you want to delete this pool?"
                          title="Delete pool"
                        >
                          <svg
                            xmlns="http://www.w3.org/2000/svg"
                            class="w-4 h-4"
                            fill="none"
                            viewBox="0 0 24 24"
                            stroke="currentColor"
                          >
                            <path
                              stroke-linecap="round"
                              stroke-linejoin="round"
                              stroke-width="2"
                              d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                            />
                          </svg>
                        </button>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
          <%= if @filter != "" do %>
            <div class="text-sm text-base-content/60 mt-2">
              Showing {length(filtered_pools(@pools, @filter))} of {length(@pools)} pools
            </div>
          <% end %>
        <% end %>
        
    <!-- Pool Form Modal -->
        <%= if @show_form do %>
          <.live_component
            module={PoolFormComponent}
            id="pool-form"
            mode={@form_mode}
            protocol={:ipv4}
            service_type={:dhcpv4}
            pool={@editing_pool}
          />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # Private Functions

  defp build_pools_csv(pools) do
    header = "Name,Network,Range Start,Range End,Lease Time,Gateway,Status\n"

    rows =
      Enum.map_join(pools, "\n", fn pool ->
        [
          csv_escape(pool.name),
          csv_escape(pool[:network] || ""),
          csv_escape(format_ip(pool.range_start) || ""),
          csv_escape(format_ip(pool.range_end) || ""),
          csv_escape(format_duration(pool.lease_time)),
          csv_escape(format_ip(pool[:gateway]) || ""),
          csv_escape(if pool[:enabled] != false, do: "Active", else: "Disabled")
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

  defp load_pools(socket) do
    pools = get_pools()
    assign(socket, :pools, pools)
  end

  defp get_pools do
    try do
      # First try the LeaseManager (when service is running, pools have full struct)
      case Process.whereis(YellowDog.Dhcpv4.LeaseManager) do
        nil ->
          # Service not running - load directly from PoolStore
          case YellowDog.Dhcpv4.PoolStore.load_pools() do
            {:ok, pools} -> pools
            {:error, _} -> []
          end

        _pid ->
          YellowDog.Dhcpv4.LeaseManager.get_pools()
      end
    catch
      _, _ -> []
    end
  end

  defp find_pool(pools, name) do
    Enum.find(pools, &(&1.name == name))
  end

  defp get_pool_stats(pool_name) do
    try do
      case YellowDog.Dhcpv4.get_pool_stats(pool_name) do
        {:ok, stats} -> stats
        _ -> default_stats()
      end
    catch
      _, _ -> default_stats()
    end
  end

  defp default_stats do
    %{
      total_addresses: 0,
      allocated_addresses: 0,
      available_addresses: 0,
      utilization_percent: 0.0
    }
  end

  defp build_pool_config(pool) do
    %{
      name: pool.name,
      network: pool.network,
      range_start: parse_ip(pool.range_start),
      range_end: parse_ip(pool.range_end),
      lease_time: pool.lease_time || 3600,
      gateway: parse_ip(pool.gateway),
      dns_servers: parse_dns_servers(pool.dns_servers),
      enabled: true
    }
    |> Map.reject(fn {_, v} -> is_nil(v) || v == "" end)
  end

  defp parse_ip(nil), do: nil
  defp parse_ip(""), do: nil

  defp parse_ip(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, {_, _, _, _} = ip_tuple} -> ip_tuple
      _ -> nil
    end
  end

  defp parse_ip(ip_tuple) when is_tuple(ip_tuple), do: ip_tuple

  defp parse_dns_servers(nil), do: nil
  defp parse_dns_servers([]), do: nil

  defp parse_dns_servers(servers) when is_list(servers) do
    for s <- servers, ip = parse_ip(s), ip != nil, do: ip
  end
end
