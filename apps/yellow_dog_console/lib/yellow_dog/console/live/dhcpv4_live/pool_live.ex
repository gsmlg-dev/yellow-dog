defmodule YellowDog.Console.Dhcpv4Live.PoolLive do
  use YellowDog.Console, :live_view

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex items-center justify-between">
        <div>
          <div class="flex items-center gap-3">
            <h1 class="text-4xl font-bold"><%= @pool_name %></h1>
            <.badge color={get_utilization_color(@pool_stats.utilization_percent)} size="lg">
              <%= Float.round(@pool_stats.utilization_percent, 1) %>% utilized
            </.badge>
          </div>
          <p class="mt-2 text-base-content/70">
            Detailed pool configuration and lease management
          </p>
        </div>
        <.link navigate={~p"/dhcpv4"} class="btn btn-ghost">
          ← Back to Overview
        </.link>
      </div>
      <!-- Pool Statistics -->
      <div class="stats stats-vertical sm:stats-horizontal shadow-xl w-full">
        <div class="stat">
          <div class="stat-title">Total Addresses</div>
          <div class="stat-value text-sm"><%= @pool_stats.total_addresses %></div>
          <div class="stat-desc">In pool range</div>
        </div>

        <div class="stat">
          <div class="stat-title">Allocated</div>
          <div class="stat-value text-sm text-success">
            <%= @pool_stats.allocated_addresses %>
          </div>
          <div class="stat-desc">Currently in use</div>
        </div>

        <div class="stat">
          <div class="stat-title">Available</div>
          <div class="stat-value text-sm text-info"><%= @pool_stats.available_addresses %></div>
          <div class="stat-desc">Ready to allocate</div>
        </div>

        <div class="stat">
          <div class="stat-title">Static Reservations</div>
          <div class="stat-value text-sm"><%= @pool_stats.static_reservations %></div>
          <div class="stat-desc">Reserved IPs</div>
        </div>
      </div>
      <!-- Utilization Progress -->
      <.card title="Pool Utilization">
        <div class="space-y-4">
          <.progress
            value={@pool_stats.utilization_percent}
            color={get_utilization_color(@pool_stats.utilization_percent)}
          />
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4 text-sm">
            <div>
              <span class="text-base-content/70">Allocated:</span>
              <span class="font-semibold ml-2">
                <%= @pool_stats.allocated_addresses %> / <%= @pool_stats.total_addresses %>
              </span>
            </div>
            <div>
              <span class="text-base-content/70">Available:</span>
              <span class="font-semibold ml-2"><%= @pool_stats.available_addresses %></span>
            </div>
            <div>
              <span class="text-base-content/70">Utilization:</span>
              <span class="font-semibold ml-2">
                <%= Float.round(@pool_stats.utilization_percent, 2) %>%
              </span>
            </div>
          </div>
        </div>
      </.card>
      <!-- Pool Configuration -->
      <.card title="Pool Configuration">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div class="space-y-3">
            <div>
              <div class="text-sm text-base-content/70">Pool Name</div>
              <div class="font-mono font-semibold"><%= @pool_config.name %></div>
            </div>

            <div>
              <div class="text-sm text-base-content/70">IP Range</div>
              <div class="font-mono font-semibold">
                <%= format_ip(@pool_config.range_start) %> - <%= format_ip(@pool_config.range_end) %>
              </div>
            </div>

            <div>
              <div class="text-sm text-base-content/70">Subnet Mask</div>
              <div class="font-mono font-semibold"><%= format_ip(@pool_config.subnet_mask) %></div>
            </div>

            <div>
              <div class="text-sm text-base-content/70">Gateway</div>
              <div class="font-mono font-semibold">
                <%= if @pool_config.gateway, do: format_ip(@pool_config.gateway), else: "Not configured" %>
              </div>
            </div>
          </div>

          <div class="space-y-3">
            <div>
              <div class="text-sm text-base-content/70">DNS Servers</div>
              <div class="font-mono font-semibold">
                <%= if @pool_config.dns_servers && length(@pool_config.dns_servers) > 0 do %>
                  <%= Enum.map_join(@pool_config.dns_servers, ", ", &format_ip/1) %>
                <% else %>
                  Not configured
                <% end %>
              </div>
            </div>

            <div>
              <div class="text-sm text-base-content/70">Domain Name</div>
              <div class="font-mono font-semibold">
                <%= @pool_config.domain_name || "Not configured" %>
              </div>
            </div>

            <div>
              <div class="text-sm text-base-content/70">Lease Time</div>
              <div class="font-mono font-semibold">
                <%= format_lease_time(@pool_config.lease_time) %>
              </div>
            </div>

            <%= if @pool_config.excluded_ranges && length(@pool_config.excluded_ranges) > 0 do %>
              <div>
                <div class="text-sm text-base-content/70">Excluded Ranges</div>
                <div class="font-mono text-sm">
                  <%= for {range_start, range_end} <- @pool_config.excluded_ranges do %>
                    <div><%= format_ip(range_start) %> - <%= format_ip(range_end) %></div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </.card>
      <!-- Lease State Distribution -->
      <%= if map_size(@pool_stats.leases_by_state) > 0 do %>
        <.card title="Lease Distribution by State">
          <div class="grid grid-cols-2 md:grid-cols-5 gap-4">
            <%= for {state, count} <- @pool_stats.leases_by_state do %>
              <div class="text-center p-4 bg-base-200 rounded-lg">
                <div class={get_state_text_color(state) <> " text-3xl font-bold"}>
                  <%= count %>
                </div>
                <div class="text-sm text-base-content/70 mt-1 capitalize">
                  <%= state %>
                </div>
              </div>
            <% end %>
          </div>
        </.card>
      <% end %>
      <!-- Static Reservations -->
      <%= if @static_reservations && length(@static_reservations) > 0 do %>
        <.card title="Static Reservations">
          <div class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>MAC Address</th>
                  <th>Reserved IP</th>
                  <th>Description</th>
                </tr>
              </thead>
              <tbody>
                <%= for reservation <- @static_reservations do %>
                  <tr>
                    <td class="font-mono text-sm"><%= format_mac(reservation.mac_address) %></td>
                    <td class="font-mono text-sm font-semibold">
                      <%= format_ip(reservation.ip_address) %>
                    </td>
                    <td class="text-sm">
                      <%= reservation.description || "-" %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </.card>
      <% end %>
      <!-- Search and Filters -->
      <.card>
        <div class="flex flex-col md:flex-row gap-4">
          <!-- Search -->
          <div class="flex-1">
            <label class="input input-bordered flex items-center gap-2">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5 opacity-70"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                />
              </svg>
              <input
                type="text"
                class="grow"
                placeholder="Search by MAC, IP, or hostname"
                value={@search_query}
                phx-change="search"
                name="search"
              />
            </label>
          </div>
          <!-- State Filter -->
          <div class="form-control w-full md:w-48">
            <select
              class="select select-bordered"
              phx-change="filter_state"
              name="state"
              value={@filter_state}
            >
              <option value="all">All States</option>
              <option value="active">Active</option>
              <option value="offered">Offered</option>
              <option value="released">Released</option>
              <option value="expired">Expired</option>
              <option value="declined">Declined</option>
            </select>
          </div>
        </div>
      </.card>
      <!-- Leases Table -->
      <.card title={"Pool Leases (#{length(@filtered_leases)})"}>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>MAC Address</th>
                <th>IP Address</th>
                <th>Hostname</th>
                <th>State</th>
                <th>Expires</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= if length(@filtered_leases) == 0 do %>
                <tr>
                  <td colspan="6" class="text-center text-base-content/50 py-8">
                    No leases found in this pool
                  </td>
                </tr>
              <% else %>
                <%= for lease <- @filtered_leases do %>
                  <tr>
                    <td>
                      <div class="font-mono text-sm">
                        <%= format_mac(lease.mac_address) %>
                      </div>
                      <%= if lease.client_id do %>
                        <div class="text-xs text-base-content/50">
                          Client ID: <%= Base.encode16(lease.client_id, case: :lower) |> String.slice(0, 16) %>...
                        </div>
                      <% end %>
                    </td>
                    <td>
                      <div class="font-mono text-sm font-semibold">
                        <%= format_ip(lease.ip_address) %>
                      </div>
                    </td>
                    <td>
                      <%= if lease.hostname do %>
                        <div class="font-medium"><%= lease.hostname %></div>
                      <% else %>
                        <span class="text-base-content/50 italic">No hostname</span>
                      <% end %>
                    </td>
                    <td>
                      <.badge color={get_state_color(lease.state)} size="sm">
                        <%= lease.state %>
                      </.badge>
                    </td>
                    <td>
                      <%= if lease.state == :active do %>
                        <div class="text-sm">
                          <%= format_expiration(lease.expires_at) %>
                        </div>
                        <div class={get_expiration_color(lease.expires_at) <> " text-xs"}>
                          <%= format_time_remaining(lease.expires_at) %>
                        </div>
                      <% else %>
                        <span class="text-base-content/50">-</span>
                      <% end %>
                    </td>
                    <td>
                      <%= if lease.state == :active do %>
                        <button
                          phx-click="release_lease"
                          phx-value-mac={format_mac(lease.mac_address)}
                          class="btn btn-xs btn-error btn-outline"
                          data-confirm="Are you sure you want to release this lease?"
                        >
                          Release
                        </button>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              <% end %>
            </tbody>
          </table>
        </div>
      </.card>
    </div>
    """
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

  defp filter_by_state(leases, state) do
    state_atom = String.to_existing_atom(state)
    Enum.filter(leases, &(&1.state == state_atom))
  rescue
    _ -> leases
  end

  defp handle_telemetry_event(event, measurements, metadata, %{pid: pid, pool_name: pool_name}) do
    if metadata[:pool_name] == pool_name do
      send(pid, {:telemetry_event, event, measurements, metadata})
    end
  end

  defp format_mac(<<mac::binary-size(6)>>) do
    mac
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_mac(_), do: "Unknown"

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(_), do: "Unknown"

  defp format_expiration(timestamp) do
    DateTime.from_unix!(timestamp)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  defp format_time_remaining(expires_at) do
    now = System.system_time(:second)
    remaining = expires_at - now

    cond do
      remaining <= 0 -> "Expired"
      remaining < 3600 -> "#{div(remaining, 60)}m remaining"
      remaining < 86400 -> "#{div(remaining, 3600)}h remaining"
      true -> "#{div(remaining, 86400)}d remaining"
    end
  end

  defp format_lease_time(seconds) when is_integer(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86400)}d"
    end
  end

  defp format_lease_time(_), do: "Unknown"

  defp get_expiration_color(expires_at) do
    now = System.system_time(:second)
    remaining = expires_at - now

    cond do
      remaining <= 0 -> "text-error"
      remaining < 3600 -> "text-error"
      remaining < 7200 -> "text-warning"
      true -> "text-base-content/50"
    end
  end

  defp get_state_color(:active), do: "success"
  defp get_state_color(:offered), do: "info"
  defp get_state_color(:released), do: "warning"
  defp get_state_color(:expired), do: "error"
  defp get_state_color(:declined), do: "error"
  defp get_state_color(_), do: "ghost"

  defp get_state_text_color(:active), do: "text-success"
  defp get_state_text_color(:offered), do: "text-info"
  defp get_state_text_color(:released), do: "text-warning"
  defp get_state_text_color(:expired), do: "text-error"
  defp get_state_text_color(:declined), do: "text-error"
  defp get_state_text_color(_), do: "text-base-content"

  defp get_utilization_color(percent) when percent >= 90, do: "error"
  defp get_utilization_color(percent) when percent >= 75, do: "warning"
  defp get_utilization_color(percent) when percent >= 50, do: "info"
  defp get_utilization_color(_), do: "success"

  defp parse_mac_string(mac_string) do
    mac_string
    |> String.replace(":", "")
    |> String.upcase()
    |> Base.decode16!()
  rescue
    _ -> <<0, 0, 0, 0, 0, 0>>
  end
end
