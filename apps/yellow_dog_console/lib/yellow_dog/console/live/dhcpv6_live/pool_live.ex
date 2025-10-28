defmodule YellowDog.Console.Dhcpv6Live.PoolLive do
  use YellowDog.Console, :live_view

  @impl true
  def mount(%{"pool_name" => pool_name}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "DHCPv6 Pool: #{pool_name}")
     |> assign(:pool_name, pool_name)
     |> load_pool_data()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-4xl font-bold"><%= @pool_name %></h1>
          <p class="mt-2 text-base-content/70">
            DHCPv6 Pool Details
          </p>
        </div>
        <.link navigate={~p"/dhcpv6"} class="btn btn-ghost">
          ← Back to Overview
        </.link>
      </div>
      <!-- Pool Statistics -->
      <%= if @pool_stats do %>
        <div class="stats stats-vertical lg:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">Total</div>
            <div class="stat-value text-2xl"><%= @pool_stats.total_count %></div>
            <div class="stat-desc">IPv6 addresses/prefixes</div>
          </div>

          <div class="stat">
            <div class="stat-title">Allocated</div>
            <div class="stat-value text-2xl text-success"><%= @pool_stats.allocated_count %></div>
            <div class="stat-desc">Currently in use</div>
          </div>

          <div class="stat">
            <div class="stat-title">Available</div>
            <div class="stat-value text-2xl text-info"><%= @pool_stats.available_count %></div>
            <div class="stat-desc">Ready to allocate</div>
          </div>

          <div class="stat">
            <div class="stat-title">Utilization</div>
            <div class={"stat-value text-2xl " <> get_utilization_text_color(@pool_stats.utilization_percent)}>
              <%= Float.round(@pool_stats.utilization_percent, 1) %>%
            </div>
            <div class="stat-desc">
              <.progress
                value={@pool_stats.utilization_percent}
                color={get_utilization_color(@pool_stats.utilization_percent)}
              />
            </div>
          </div>
        </div>

        <!-- Pool Configuration -->
        <.card title="Pool Configuration">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <div class="text-sm text-base-content/70 mb-1">Pool Name</div>
              <div class="font-mono"><%= @pool_name %></div>
            </div>

            <%= if @pool_config do %>
              <%= if @pool_config[:range_start] do %>
                <div>
                  <div class="text-sm text-base-content/70 mb-1">Address Range</div>
                  <div class="font-mono text-sm">
                    <%= format_ipv6(@pool_config.range_start) %>
                    <br />→ <%= format_ipv6(@pool_config.range_end) %>
                  </div>
                </div>
              <% end %>

              <%= if @pool_config[:prefix] do %>
                <div>
                  <div class="text-sm text-base-content/70 mb-1">Prefix Pool</div>
                  <div class="font-mono text-sm">
                    <%= format_prefix({@pool_config.prefix, @pool_config.prefix_length}) %>
                  </div>
                </div>

                <div>
                  <div class="text-sm text-base-content/70 mb-1">Delegated Length</div>
                  <div class="font-mono">/<%= @pool_config.delegated_length %></div>
                </div>
              <% end %>

              <%= if @pool_config[:dns_servers] && length(@pool_config.dns_servers) > 0 do %>
                <div>
                  <div class="text-sm text-base-content/70 mb-1">DNS Servers</div>
                  <div class="font-mono text-sm">
                    <%= for dns <- @pool_config.dns_servers do %>
                      <div><%= format_ipv6(dns) %></div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if @pool_config[:domain_name] do %>
                <div>
                  <div class="text-sm text-base-content/70 mb-1">Domain Name</div>
                  <div class="font-mono"><%= @pool_config.domain_name %></div>
                </div>
              <% end %>

              <div>
                <div class="text-sm text-base-content/70 mb-1">Preferred Lifetime</div>
                <div class="font-mono"><%= format_lifetime(@pool_config[:preferred_lifetime]) %></div>
              </div>

              <div>
                <div class="text-sm text-base-content/70 mb-1">Valid Lifetime</div>
                <div class="font-mono"><%= format_lifetime(@pool_config[:valid_lifetime]) %></div>
              </div>
            <% end %>

            <div>
              <div class="text-sm text-base-content/70 mb-1">Static Reservations</div>
              <div class="font-mono"><%= @pool_stats.static_reservations %></div>
            </div>
          </div>
        </.card>

        <!-- Lease State Distribution -->
        <%= if map_size(@pool_stats.leases_by_state) > 0 do %>
          <.card title="Lease Distribution by State">
            <div class="grid grid-cols-2 md:grid-cols-5 gap-4">
              <%= for {state, count} <- @pool_stats.leases_by_state do %>
                <div class="text-center p-4 bg-base-200 rounded-lg">
                  <div class={"text-3xl font-bold " <> get_state_text_color(state)}>
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

        <!-- Active Leases for this Pool -->
        <.card title="Recent Leases">
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>DUID</th>
                  <th>IAID</th>
                  <th>IPv6 / Prefix</th>
                  <th>IA Type</th>
                  <th>State</th>
                  <th>Expires</th>
                </tr>
              </thead>
              <tbody>
                <%= if Enum.empty?(@leases) do %>
                  <tr>
                    <td colspan="6" class="text-center py-4 text-base-content/70">
                      No active leases in this pool
                    </td>
                  </tr>
                <% else %>
                  <%= for lease <- Enum.take(@leases, 10) do %>
                    <tr>
                      <td>
                        <code class="text-xs"><%= format_duid_short(lease.duid) %></code>
                      </td>
                      <td><%= lease.iaid %></td>
                      <td>
                        <code class="text-xs">
                          <%= if lease.ia_type == :ia_pd do %>
                            <%= format_prefix(lease.delegated_prefix) %>
                          <% else %>
                            <%= format_ipv6(lease.ip_address) %>
                          <% end %>
                        </code>
                      </td>
                      <td>
                        <.badge color={get_ia_type_color(lease.ia_type)} size="sm">
                          <%= format_ia_type(lease.ia_type) %>
                        </.badge>
                      </td>
                      <td>
                        <.badge color={get_state_color(lease.state)} size="sm">
                          <%= lease.state %>
                        </.badge>
                      </td>
                      <td class="text-xs">
                        <%= if lease.expires_at do %>
                          <%= format_expires(lease.expires_at) %>
                        <% else %>
                          N/A
                        <% end %>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>

          <:actions>
            <.link navigate={~p"/dhcpv6/leases"} class="btn btn-sm btn-ghost">
              View All Leases →
            </.link>
          </:actions>
        </.card>
      <% else %>
        <.card>
          <div class="text-center py-8">
            <div class="text-error text-lg mb-2">Pool Not Found</div>
            <div class="text-base-content/70">
              The pool "<%= @pool_name %>" does not exist or is not configured.
            </div>
          </div>
        </.card>
      <% end %>
    </div>
    """
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
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_duid(_), do: "Unknown"

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
end
