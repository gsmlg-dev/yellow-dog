defmodule YellowDog.Console.NetmanLive.ResolvedLive do
  @moduledoc """
  Management-backed Resolved state and configuration for one selected Netman.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.NetmanManagement
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Resolved",
       subscribed_netman_id: nil,
       apply_mode: nil,
       upstreams: [],
       search_domains: [],
       cache_entries: [],
       counters: %{"hits" => 0, "misses" => 0},
       config_revision: nil,
       cache_revision: nil,
       management_error: nil,
       operation_result: nil,
       cached_observed_at: nil,
       config_bootstrap?: false,
       config_read_error?: false,
       config_enabled?: false,
       commands_enabled?: false,
       resolved_form: to_form(%{"upstreams" => "", "search_domains" => ""}, as: "resolved"),
       rollback_form: to_form(%{"target_revision" => ""}, as: "rollback")
     )}
  end

  @impl true
  def handle_params(%{"netman_id" => netman_id}, _uri, socket) do
    socket = subscribe(socket, netman_id)
    {:noreply, if(connected?(socket), do: load_resolved(socket, netman_id), else: socket)}
  end

  @impl true
  def handle_event("update_resolved", %{"resolved" => params}, socket) do
    with :ok <- configurable(socket),
         {:ok, revision} <- update_revision(socket) do
      payload = %{
        "upstreams" => csv(params["upstreams"]),
        "search_domains" => csv(params["search_domains"])
      }

      result =
        NetmanManagement.resolved_config_update(
          selected_id(socket),
          payload,
          expected_revision: revision
        )

      {:noreply, finish(socket, result, "Desired Resolved configuration published")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("rollback_resolved", %{"rollback" => params}, socket) do
    with :ok <- configurable(socket),
         {:ok, revision} <- exact_revision(socket.assigns.config_revision, "configuration") do
      result =
        NetmanManagement.resolved_config_rollback(
          selected_id(socket),
          %{"target_revision" => params["target_revision"]},
          expected_revision: revision
        )

      {:noreply, finish(socket, result, "Desired Resolved rollback published")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("flush_cache", _params, socket) do
    with :ok <- mutable(socket),
         {:ok, revision} <- exact_revision(socket.assigns.cache_revision, "cache") do
      result =
        NetmanManagement.resolved_cache_flush(
          selected_id(socket),
          %{},
          expected_revision: revision,
          idempotency_key: Ecto.UUID.generate()
        )

      socket =
        case result do
          %ManagementResult{status: :ok} ->
            assign(socket, cache_entries: [], cache_revision: nil)

          _result ->
            socket
        end

      message =
        case result do
          %ManagementResult{status: :ok, value: %{"cleared_entries" => count}} ->
            "Flushed #{count} cache entries"

          _result ->
            nil
        end

      {:noreply, finish(socket, result, message)}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:netman_connection, _state, %{netman_id: netman_id}}, socket)
      when netman_id == socket.assigns.selected_netman.id do
    {:noreply, socket |> refresh_selected_netman(netman_id) |> load_resolved(netman_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="netman-resolved">
        <div class="flex items-center gap-2">
          <.link
            navigate={ServicePaths.netman_path(@selected_netman.id, :overview)}
            class="btn btn-ghost btn-sm btn-circle"
          >
            <.dm_mdi name="arrow-left" class="h-5 w-5" />
          </.link>
          <div>
            <div class="flex items-center gap-3">
              <h1 class="text-4xl font-bold">Resolved</h1>
              <.badge color={if @service_online?, do: "success", else: "ghost"} size="sm">
                {if @service_online?, do: "Connected", else: "Offline"}
              </.badge>
            </div>
            <p class="mt-1 text-on-surface-variant">
              {@selected_netman.name || @selected_netman.id} · Apply mode: {display(@apply_mode)}
            </p>
          </div>
        </div>

        <.offline_snapshot :if={not @service_online?} observed_at={@cached_observed_at} />
        <div :if={@apply_mode == "observe"} class="alert alert-warning">
          Observe mode is read-only. Resolved mutations are disabled.
        </div>
        <div :if={@apply_mode == "observe_first"} class="alert alert-info">
          Resolved mutations require the observe-first policy gate.
        </div>
        <.operation_error :if={error_result?(@management_error)} result={@management_error} />
        <.operation_error :if={error_result?(@operation_result)} result={@operation_result} />

        <div class="grid grid-cols-2 gap-4 sm:grid-cols-4">
          <.card>
            <div class="text-sm text-on-surface-variant">Upstreams</div>
            <div class="text-2xl font-bold text-primary">{length(@upstreams)}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Search domains</div>
            <div class="text-2xl font-bold text-info">{length(@search_domains)}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Cache hits</div>
            <div class="text-2xl font-bold text-success">{@counters["hits"]}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Cache misses</div>
            <div class="text-2xl font-bold text-warning">{@counters["misses"]}</div>
          </.card>
        </div>

        <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
          <.card title="Upstream DNS servers">
            <p :if={@upstreams == []} class="text-sm text-on-surface-variant">
              No upstreams reported
            </p>
            <div :for={upstream <- @upstreams} class="flex items-center justify-between py-2">
              <span class="font-mono">{upstream["address"]}</span>
              <.badge color="ghost" size="sm">{upstream["source"]}</.badge>
            </div>
          </.card>

          <.card title="Search domains">
            <p :if={@search_domains == []} class="text-sm text-on-surface-variant">
              No search domains reported
            </p>
            <div :for={domain <- @search_domains} class="flex items-center justify-between py-2">
              <span class="font-mono">{domain["domain"]}</span>
              <.badge color={if domain["routing_only"], do: "info", else: "ghost"} size="sm">
                {if domain["routing_only"], do: "routing only", else: "search"}
              </.badge>
            </div>
          </.card>
        </div>

        <.card title="Resolved cache">
          <:actions>
            <button
              phx-click="flush_cache"
              phx-value-expected_revision={@cache_revision}
              class="btn btn-warning btn-sm"
              disabled={not @commands_enabled? or not revision_available?(@cache_revision)}
            >
              Flush cache
            </button>
          </:actions>
          <div :if={@cache_entries == []} class="text-sm text-on-surface-variant">
            Cache is empty
          </div>
          <div :if={@cache_entries != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Domain</th><th>Address</th><th>Expires</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @cache_entries}>
                  <td class="font-mono">{entry["domain"]}</td>
                  <td class="font-mono">{entry["address"]}</td>
                  <td>{entry["expires_at"]}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
          <.card title="Publish Resolved configuration">
            <.form
              for={@resolved_form}
              id="resolved-config-form"
              phx-submit="update_resolved"
              class="space-y-3"
            >
              <.field field={@resolved_form[:upstreams]} label="Upstreams (comma separated)" />
              <.field
                field={@resolved_form[:search_domains]}
                label="Search domains (comma separated)"
              />
              <button
                class="btn btn-primary"
                disabled={
                  not @config_enabled? or
                    (not @config_bootstrap? and not revision_available?(@config_revision))
                }
              >
                Publish
              </button>
            </.form>
          </.card>

          <.card title="Rollback Resolved configuration">
            <.form
              for={@rollback_form}
              id="resolved-rollback-form"
              phx-submit="rollback_resolved"
              class="space-y-3"
            >
              <.field field={@rollback_form[:target_revision]} label="Target revision" required />
              <button
                class="btn btn-warning"
                disabled={not @config_enabled? or not revision_available?(@config_revision)}
              >
                Rollback
              </button>
            </.form>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp field(assigns) do
    assigns = assign_new(assigns, :required, fn -> false end)

    ~H"""
    <label class="form-control">
      <span class="label"><span class="label-text">{@label}</span></span>
      <input
        type="text"
        name={@field.name}
        value={@field.value}
        required={@required}
        class="input input-bordered w-full"
      />
    </label>
    """
  end

  defp offline_snapshot(assigns) do
    ~H"""
    <div class="alert alert-warning" id="offline-snapshot">
      <.dm_mdi name="cloud-off-outline" class="h-5 w-5" />
      <div>
        <div class="font-semibold">Offline cached snapshot</div>
        <div class="text-sm">Observed {format_observed_at(@observed_at)}</div>
      </div>
    </div>
    """
  end

  defp operation_error(assigns) do
    ~H"""
    <div class="alert alert-error">
      <.dm_mdi name="alert-circle" class="h-5 w-5" />
      <span>{@result.message}</span>
    </div>
    """
  end

  defp load_resolved(socket, netman_id) do
    config_result = NetmanManagement.resolved_config(netman_id)
    mode_result = NetmanManagement.runtime_apply_mode_get(netman_id)
    upstream_result = NetmanManagement.resolved_upstreams_list(netman_id)
    domains_result = NetmanManagement.resolved_search_domains_list(netman_id)
    cache_result = NetmanManagement.resolved_cache_get(netman_id)
    counters_result = NetmanManagement.resolved_counters_get(netman_id)

    runtime_results = [
      mode_result,
      upstream_result,
      domains_result,
      cache_result,
      counters_result
    ]

    results = [config_result | runtime_results]
    apply_mode = mode_result |> value(%{}) |> Map.get("mode")
    upstream_value = value(upstream_result, %{})
    cache_value = value(cache_result, %{})
    managed_config = value(config_result, nil)
    config_bootstrap? = match?(%ManagementResult{status: :ok, value: nil}, config_result)
    config_read_error? = error_result?(config_result)

    assign(socket,
      page_title: "#{socket.assigns.selected_netman.name || netman_id} — Resolved",
      apply_mode: apply_mode,
      upstreams: Map.get(upstream_value, "items", []),
      search_domains: items(domains_result),
      cache_entries: Map.get(cache_value, "entries", []),
      counters: value(counters_result, %{"hits" => 0, "misses" => 0}),
      config_revision: editable_config_revision(managed_config),
      cache_revision: Map.get(cache_value, "revision"),
      management_error: first_error(results),
      resolved_form: resolved_form(managed_config),
      cached_observed_at:
        cached_observed_at(runtime_results, socket.assigns.selected_netman.last_seen_at),
      config_bootstrap?: config_bootstrap?,
      config_read_error?: config_read_error?,
      config_enabled?: not config_read_error? and apply_mode != "observe",
      commands_enabled?: socket.assigns.service_online? and apply_mode != "observe"
    )
  end

  defp resolved_form(%{
         payload: %{"upstreams" => upstreams, "search_domains" => search_domains}
       })
       when is_list(upstreams) and is_list(search_domains) do
    to_form(
      %{
        "upstreams" => Enum.join(upstreams, ", "),
        "search_domains" => Enum.join(search_domains, ", ")
      },
      as: "resolved"
    )
  end

  defp resolved_form(_config),
    do: to_form(%{"upstreams" => "", "search_domains" => ""}, as: "resolved")

  defp editable_config_revision(%{applied_revision: revision}) when is_binary(revision),
    do: revision

  defp editable_config_revision(%{expected_revision: revision}) when is_binary(revision),
    do: revision

  defp editable_config_revision(_config), do: nil

  defp configurable(%{assigns: %{config_read_error?: true}}),
    do: {:error, "Management-owned Resolved configuration is unavailable"}

  defp configurable(%{assigns: %{apply_mode: "observe"}}),
    do: {:error, "Observe mode is read-only"}

  defp configurable(_socket), do: :ok

  defp update_revision(%{assigns: %{config_bootstrap?: true}}), do: {:ok, nil}

  defp update_revision(socket),
    do: exact_revision(socket.assigns.config_revision, "configuration")

  defp mutable(%{assigns: %{service_online?: false}}),
    do: {:error, "The selected Netman is offline; commands are disabled"}

  defp mutable(%{assigns: %{apply_mode: "observe"}}),
    do: {:error, "Observe mode is read-only"}

  defp mutable(_socket), do: :ok

  defp finish(socket, %ManagementResult{status: :ok} = result, message) when is_binary(message) do
    socket
    |> assign(operation_result: result)
    |> put_flash(:info, message)
  end

  defp finish(socket, %ManagementResult{status: :ok} = result, _message),
    do: assign(socket, operation_result: result)

  defp finish(socket, %ManagementResult{} = result, _message) do
    socket
    |> assign(operation_result: result)
    |> put_flash(:error, result.message)
  end

  defp subscribe(socket, netman_id) do
    if connected?(socket) and socket.assigns.subscribed_netman_id != netman_id do
      if old_id = socket.assigns.subscribed_netman_id do
        Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "management:netman:#{old_id}")
      end

      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "management:netman:#{netman_id}")
    end

    assign(socket, :subscribed_netman_id, netman_id)
  end

  defp refresh_selected_netman(socket, netman_id) do
    case ManagementCore.get_netman(netman_id) do
      {:ok, netman} ->
        assign(socket,
          selected_netman: netman,
          service_online?: netman.status in [:online, "online"],
          snapshot_observed_at: netman.last_seen_at
        )

      _error ->
        socket
    end
  end

  defp selected_id(socket), do: socket.assigns.selected_netman.id

  defp exact_revision(revision, owner) do
    case Digest.validate(revision) do
      {:ok, revision} -> {:ok, revision}
      _error -> {:error, "The exact #{owner} revision is unavailable"}
    end
  end

  defp revision_available?(revision), do: match?({:ok, _revision}, Digest.validate(revision))

  defp csv(value) when value in [nil, ""], do: []

  defp csv(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp value(%ManagementResult{status: :ok, value: value}, _default), do: value
  defp value(_result, default), do: default
  defp items(result), do: result |> value(%{}) |> Map.get("items", [])

  defp first_error(results) do
    Enum.find_value(results, fn
      %ManagementResult{status: :error} = result -> result
      _result -> nil
    end)
  end

  defp cached_observed_at(results, fallback) do
    Enum.find_value(results, fallback, fn
      %ManagementResult{source: :cache, observed_at: observed_at} -> observed_at
      _result -> nil
    end)
  end

  defp error_result?(%ManagementResult{status: :error}), do: true
  defp error_result?(_result), do: false

  defp display(nil), do: "-"
  defp display(value) when is_atom(value), do: value |> Atom.to_string() |> display()
  defp display(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp display(value), do: to_string(value)

  defp format_observed_at(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  defp format_observed_at(value) when is_binary(value), do: value
  defp format_observed_at(_value), do: "unknown"
end
