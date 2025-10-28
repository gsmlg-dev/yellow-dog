defmodule YellowDog.Console.Dhcpv4Live.LeasesLive do
  use YellowDog.Console, :live_view

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
  def handle_info({:telemetry_event, _event, _measurements, _metadata}, socket) do
    {:noreply, load_leases(socket)}
  end

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach("dhcpv4-leases-#{inspect(self())}")
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-4xl font-bold">DHCP Leases</h1>
          <p class="mt-2 text-base-content/70">
            View and manage all DHCP lease allocations
          </p>
        </div>
        <.link navigate={~p"/dhcpv4"} class="btn btn-ghost">
          ← Back to Overview
        </.link>
      </div>
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
          <!-- Pool Filter -->
          <div class="form-control w-full md:w-48">
            <select
              class="select select-bordered"
              phx-change="filter_pool"
              name="pool"
              value={@filter_pool}
            >
              <option value="all">All Pools</option>
              <%= for pool <- @pools do %>
                <option value={pool}><%= pool %></option>
              <% end %>
            </select>
          </div>
        </div>
      </.card>
      <!-- Stats Summary -->
      <div class="stats stats-vertical sm:stats-horizontal shadow">
        <div class="stat">
          <div class="stat-title">Total Displayed</div>
          <div class="stat-value text-sm"><%= length(@filtered_leases) %></div>
        </div>
        <div class="stat">
          <div class="stat-title">Active</div>
          <div class="stat-value text-sm text-success">
            <%= count_by_state(@filtered_leases, :active) %>
          </div>
        </div>
        <div class="stat">
          <div class="stat-title">Offered</div>
          <div class="stat-value text-sm text-info">
            <%= count_by_state(@filtered_leases, :offered) %>
          </div>
        </div>
        <div class="stat">
          <div class="stat-title">Expired</div>
          <div class="stat-value text-sm text-warning">
            <%= count_by_state(@filtered_leases, :expired) %>
          </div>
        </div>
      </div>
      <!-- Leases Table -->
      <.card>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>MAC Address</th>
                <th>IP Address</th>
                <th>Hostname</th>
                <th>Pool</th>
                <th>State</th>
                <th>Expires</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= if length(@filtered_leases) == 0 do %>
                <tr>
                  <td colspan="7" class="text-center text-base-content/50 py-8">
                    No leases found matching your criteria
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
                      <.badge size="sm"><%= lease.pool_name %></.badge>
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
                        <div class={"text-xs " <> get_expiration_color(lease.expires_at)}>
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
    case Code.ensure_loaded?(YellowDog.Dhcpv4) do
      true ->
        try do
          YellowDog.Dhcpv4.list_leases()
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end

      false ->
        []
    end
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
      mac_match = format_mac(lease.mac_address) |> String.downcase() |> String.contains?(query_lower)
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

  defp parse_mac_string(mac_string) do
    mac_string
    |> String.replace(":", "")
    |> String.upcase()
    |> Base.decode16!()
  rescue
    _ -> <<0, 0, 0, 0, 0, 0>>
  end
end
