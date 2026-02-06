defmodule YellowDog.Console.DnsLive.MetricsLive do
  @moduledoc """
  DNS Metrics dashboard page.

  Shows query statistics, response time distribution, cache hit rates,
  top queried domains, and top clients from the MetricsCollector.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Dns.MetricsCollector

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS Metrics")
     |> assign(:metrics, fetch_metrics())
     |> assign(:summary, fetch_summary())
     |> assign(:top_domains, fetch_top_domains())
     |> assign(:top_clients, fetch_top_clients())
     |> assign(:response_times, fetch_response_times())}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    try do
      MetricsCollector.reset()
    catch
      :exit, _ -> :ok
    end

    {:noreply,
     socket
     |> assign(:metrics, fetch_metrics())
     |> assign(:summary, fetch_summary())
     |> assign(:top_domains, fetch_top_domains())
     |> assign(:top_clients, fetch_top_clients())
     |> assign(:response_times, fetch_response_times())
     |> put_flash(:info, "Metrics reset")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket =
      socket
      |> assign(:metrics, fetch_metrics())
      |> assign(:summary, fetch_summary())
      |> assign(:top_domains, fetch_top_domains())
      |> assign(:top_clients, fetch_top_clients())
      |> assign(:response_times, fetch_response_times())

    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp fetch_metrics do
    try do
      MetricsCollector.get_metrics()
    catch
      :exit, _ -> default_metrics()
    end
  end

  defp fetch_summary do
    try do
      MetricsCollector.summary()
    catch
      :exit, _ -> default_summary()
    end
  end

  defp fetch_top_domains do
    try do
      MetricsCollector.get_top_domains(limit: 10)
    catch
      :exit, _ -> []
    end
  end

  defp fetch_top_clients do
    try do
      MetricsCollector.get_top_clients(limit: 10)
    catch
      :exit, _ -> []
    end
  end

  defp fetch_response_times do
    try do
      MetricsCollector.get_response_times()
    catch
      :exit, _ -> %{count: 0, sum: 0, min: 0, max: 0, avg: 0.0, buckets: []}
    end
  end

  defp default_metrics do
    %{
      counters: %{
        queries_total: 0,
        cache_hits: 0,
        cache_misses: 0,
        rate_limit_rejected: 0,
        fallbacks_total: 0
      },
      queries_by_protocol: [],
      queries_by_type: [],
      responses_by_code: [],
      top_domains: [],
      top_clients: [],
      response_times: %{count: 0},
      started_at: DateTime.utc_now()
    }
  end

  defp default_summary do
    %{
      queries_total: 0,
      cache_hit_rate: 0.0,
      avg_response_time_us: 0.0,
      uptime_seconds: 0
    }
  end

  defp fmt_count(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp fmt_count(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}k"
  end

  defp fmt_count(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt_count(n) when is_float(n), do: Float.to_string(Float.round(n, 1))
  defp fmt_count(_), do: "0"

  defp format_latency(us) when is_float(us) and us >= 1_000 do
    "#{Float.round(us / 1_000, 1)}ms"
  end

  defp format_latency(us) when is_float(us), do: "#{Float.round(us, 0)}us"
  defp format_latency(us) when is_integer(us) and us >= 1_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp format_latency(us) when is_integer(us), do: "#{us}us"
  defp format_latency(_), do: "0us"

  defp format_uptime(seconds) when is_number(seconds) do
    hours = div(trunc(seconds), 3600)
    mins = div(rem(trunc(seconds), 3600), 60)

    cond do
      hours > 0 -> "#{hours}h #{mins}m"
      mins > 0 -> "#{mins}m"
      true -> "#{trunc(seconds)}s"
    end
  end

  defp format_uptime(_), do: "0s"

  defp bar_width(count, max) when max > 0, do: Float.round(count / max * 100, 0)
  defp bar_width(_, _), do: 0

  defp rcode_color("noerror"), do: "bg-success"
  defp rcode_color("nxdomain"), do: "bg-warning"
  defp rcode_color("servfail"), do: "bg-error"
  defp rcode_color("refused"), do: "bg-error"
  defp rcode_color(_), do: "bg-base-300"

  defp type_color("a"), do: "bg-primary"
  defp type_color("aaaa"), do: "bg-secondary"
  defp type_color("mx"), do: "bg-accent"
  defp type_color("cname"), do: "bg-info"
  defp type_color("txt"), do: "bg-warning"
  defp type_color("ns"), do: "bg-success"
  defp type_color(_), do: "bg-base-300"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex flex-wrap justify-between items-center gap-4">
          <h1 class="text-2xl font-bold">DNS Metrics</h1>
          <div class="flex gap-2 items-center">
            <span class="text-xs text-base-content/50">Auto-refresh: 5s</span>
            <button phx-click="reset" class="btn btn-sm btn-ghost" data-confirm="Reset all metrics?">
              Reset
            </button>
          </div>
        </div>

        <%!-- Summary Stats --%>
        <div class="stats stats-vertical lg:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">Total Queries</div>
            <div class="stat-value">{fmt_count(@summary.queries_total)}</div>
            <div class="stat-desc">Since start</div>
          </div>
          <div class="stat">
            <div class="stat-title">Avg Latency</div>
            <div class="stat-value text-primary">{format_latency(@summary.avg_response_time_us)}</div>
            <div class="stat-desc">Response time</div>
          </div>
          <div class="stat">
            <div class="stat-title">Cache Hit Rate</div>
            <div class="stat-value text-success">{Float.round(@summary.cache_hit_rate, 1)}%</div>
            <div class="stat-desc">
              {Map.get(@metrics.counters, :cache_hits, 0)} hits / {Map.get(@metrics.counters, :cache_misses, 0)} misses
            </div>
          </div>
          <div class="stat">
            <div class="stat-title">Uptime</div>
            <div class="stat-value text-lg">{format_uptime(@summary.uptime_seconds)}</div>
            <div class="stat-desc">Collector running</div>
          </div>
        </div>

        <%!-- Response Codes & Query Types --%>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <%!-- Response Codes --%>
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-base">Response Codes</h2>
              <%= if Enum.empty?(@metrics.responses_by_code) do %>
                <p class="text-base-content/50 text-sm">No responses recorded yet</p>
              <% else %>
                <% max_rcode = @metrics.responses_by_code |> Enum.map(fn {_, c} -> c end) |> Enum.max(fn -> 1 end) %>
                <div class="space-y-2">
                  <%= for {code, count} <- Enum.sort_by(@metrics.responses_by_code, fn {_, c} -> -c end) do %>
                    <div class="flex items-center gap-2">
                      <span class="w-24 text-sm font-mono">{code |> to_string() |> String.upcase()}</span>
                      <div class="flex-1 bg-base-200 rounded-full h-4">
                        <div
                          class={"h-4 rounded-full " <> rcode_color(to_string(code))}
                          style={"width: #{bar_width(count, max_rcode)}%"}
                        >
                        </div>
                      </div>
                      <span class="text-sm w-16 text-right">{fmt_count(count)}</span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Query Types --%>
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-base">Query Types</h2>
              <%= if Enum.empty?(@metrics.queries_by_type) do %>
                <p class="text-base-content/50 text-sm">No queries recorded yet</p>
              <% else %>
                <% max_type = @metrics.queries_by_type |> Enum.map(fn {_, c} -> c end) |> Enum.max(fn -> 1 end) %>
                <div class="space-y-2">
                  <%= for {type, count} <- Enum.sort_by(@metrics.queries_by_type, fn {_, c} -> -c end) do %>
                    <div class="flex items-center gap-2">
                      <span class="w-16 text-sm font-mono">{type |> to_string() |> String.upcase()}</span>
                      <div class="flex-1 bg-base-200 rounded-full h-4">
                        <div
                          class={"h-4 rounded-full " <> type_color(to_string(type))}
                          style={"width: #{bar_width(count, max_type)}%"}
                        >
                        </div>
                      </div>
                      <span class="text-sm w-16 text-right">{fmt_count(count)}</span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Response Time Histogram --%>
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-base">Response Time Distribution</h2>
            <%= if @response_times.count == 0 do %>
              <p class="text-base-content/50 text-sm">No response times recorded yet</p>
            <% else %>
              <div class="grid grid-cols-3 gap-4 mb-4">
                <div class="text-center">
                  <div class="text-xs text-base-content/60">Min</div>
                  <div class="font-mono">{format_latency(@response_times.min)}</div>
                </div>
                <div class="text-center">
                  <div class="text-xs text-base-content/60">Avg</div>
                  <div class="font-mono">{format_latency(@response_times.avg)}</div>
                </div>
                <div class="text-center">
                  <div class="text-xs text-base-content/60">Max</div>
                  <div class="font-mono">{format_latency(@response_times.max)}</div>
                </div>
              </div>
              <% max_bucket = @response_times.buckets |> Enum.map(fn {_, c} -> c end) |> Enum.max(fn -> 1 end) %>
              <div class="flex items-end gap-1 h-32">
                <%= for {label, count} <- @response_times.buckets do %>
                  <div class="flex-1 flex flex-col items-center">
                    <div
                      class="bg-primary w-full rounded-t"
                      style={"height: #{bar_width(count, max_bucket)}%"}
                    >
                    </div>
                    <div class="text-xs text-base-content/60 mt-1 truncate w-full text-center">
                      {format_bucket_label(label)}
                    </div>
                    <div class="text-xs">{count}</div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Top Domains & Top Clients --%>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <%!-- Top Domains --%>
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-base">Top Queried Domains</h2>
              <%= if Enum.empty?(@top_domains) do %>
                <p class="text-base-content/50 text-sm">No domains queried yet</p>
              <% else %>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>#</th>
                        <th>Domain</th>
                        <th class="text-right">Queries</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for {{domain, count}, idx} <- Enum.with_index(@top_domains, 1) do %>
                        <tr class="hover">
                          <td class="text-base-content/60">{idx}</td>
                          <td class="font-mono text-sm">{domain}</td>
                          <td class="text-right">{fmt_count(count)}</td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Top Clients --%>
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-base">Top Clients</h2>
              <%= if Enum.empty?(@top_clients) do %>
                <p class="text-base-content/50 text-sm">No client activity yet</p>
              <% else %>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>#</th>
                        <th>Client IP</th>
                        <th class="text-right">Queries</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for {{ip, count}, idx} <- Enum.with_index(@top_clients, 1) do %>
                        <tr class="hover">
                          <td class="text-base-content/60">{idx}</td>
                          <td class="font-mono text-sm">{ip}</td>
                          <td class="text-right">{fmt_count(count)}</td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Additional Counters --%>
        <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">Rate Limited</div>
            <div class="stat-value text-lg text-warning">{Map.get(@metrics.counters, :rate_limit_rejected, 0)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Fallbacks Used</div>
            <div class="stat-value text-lg">{Map.get(@metrics.counters, :fallbacks_total, 0)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Protocol Split</div>
            <div class="stat-value text-lg">
              <% proto = Map.new(@metrics.queries_by_protocol) %>
              <span class="text-info">{Map.get(proto, :udp, 0)} UDP</span>
              <span class="text-xs text-base-content/50"> / </span>
              <span class="text-primary">{Map.get(proto, :tcp, 0)} TCP</span>
            </div>
          </div>
        </div>

        <%!-- Footer --%>
        <div class="text-xs text-base-content/50 flex justify-between">
          <span>Data from MetricsCollector</span>
          <span :if={connected?(@socket)} class="flex items-center gap-1">
            <span class="w-2 h-2 bg-success rounded-full animate-pulse"></span> Connected
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_bucket_label(:inf), do: "+inf"
  defp format_bucket_label(us) when is_integer(us) and us >= 1_000_000, do: "#{div(us, 1_000_000)}s"
  defp format_bucket_label(us) when is_integer(us) and us >= 1_000, do: "#{div(us, 1_000)}ms"
  defp format_bucket_label(us) when is_integer(us), do: "#{us}us"
  defp format_bucket_label(other), do: to_string(other)
end
