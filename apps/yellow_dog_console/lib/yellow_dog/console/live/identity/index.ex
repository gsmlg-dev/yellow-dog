defmodule YellowDog.Console.IdentityLive.ManagementSupport do
  @moduledoc false

  alias Phoenix.LiveView
  alias YellowDog.Console.ManagementResult
  alias YellowDog.ManagementCore

  def subscribe(socket, server_id) do
    if Phoenix.LiveView.connected?(socket) and
         socket.assigns[:subscribed_server_id] != server_id do
      if old_id = socket.assigns[:subscribed_server_id] do
        Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "management:server:#{old_id}")
      end

      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "management:server:#{server_id}")
    end

    Phoenix.Component.assign(socket, :subscribed_server_id, server_id)
  end

  def refresh_selected_server(socket, server_id) do
    case ManagementCore.get_server(server_id) do
      {:ok, server} ->
        Phoenix.Component.assign(socket,
          selected_server: server,
          service_online?: server.status in [:online, "online"],
          snapshot_observed_at: server.last_seen_at
        )

      _error ->
        socket
    end
  end

  def selected_id(socket), do: socket.assigns.selected_server.id

  def mutable(%{assigns: %{service_online?: false}}),
    do: {:error, "The selected Server is offline; commands are disabled"}

  def mutable(_socket), do: :ok

  def command_options(expected_revision) do
    [
      expected_revision: expected_revision,
      idempotency_key: Ecto.UUID.generate()
    ]
  end

  def items(%ManagementResult{status: :ok, value: %{"items" => items}}) when is_list(items),
    do: items

  def items(_result), do: []

  def value(%ManagementResult{status: :ok, value: value}, default),
    do: if(is_nil(value), do: default, else: value)

  def value(_result, default), do: default

  def error(%ManagementResult{status: :error} = result), do: result
  def error(_result), do: nil

  def cached?(%ManagementResult{source: :cache}), do: true
  def cached?(_result), do: false

  def cached_observed_at(%ManagementResult{source: :cache, observed_at: observed_at}, _fallback),
    do: observed_at

  def cached_observed_at(_result, fallback), do: fallback

  def finish(socket, %ManagementResult{status: :ok}, message),
    do: LiveView.put_flash(socket, :info, message)

  def finish(socket, %ManagementResult{status: :error, message: message}, _success_message),
    do: LiveView.put_flash(socket, :error, message)

  def replace(items, %{"host_id" => id} = replacement) do
    Enum.map(items, fn
      %{"host_id" => ^id} -> replacement
      item -> item
    end)
  end

  def format_observed_at(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  def format_observed_at(value) when is_binary(value), do: value
  def format_observed_at(_value), do: "unknown"
end

defmodule YellowDog.Console.IdentityLive.ManagementComponents do
  @moduledoc false

  use YellowDog.Console, :html

  alias YellowDog.Console.IdentityLive.ManagementSupport

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :server, :map, required: true
  attr :online?, :boolean, required: true
  attr :back, :string, default: nil

  def page_header(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <.link :if={@back} navigate={@back} class="btn btn-ghost btn-sm btn-circle" aria-label="Back">
        <.dm_mdi name="arrow-left" class="h-5 w-5" />
      </.link>
      <div>
        <div class="flex items-center gap-3">
          <h1 class="text-4xl font-bold">{@title}</h1>
          <.badge color={if @online?, do: "success", else: "ghost"} size="sm">
            {if @online?, do: "Connected", else: "Offline"}
          </.badge>
        </div>
        <p class="mt-1 text-on-surface-variant">
          {@server.name || @server.id}<span :if={@subtitle}> · {@subtitle}</span>
        </p>
      </div>
    </div>
    """
  end

  attr :observed_at, :any, required: true

  def offline_snapshot(assigns) do
    ~H"""
    <div class="alert alert-warning" id="identity-offline-snapshot">
      <.dm_mdi name="cloud-off-outline" class="h-5 w-5" />
      <div>
        <div class="font-semibold">Offline cached snapshot</div>
        <div class="text-sm">
          Observed {ManagementSupport.format_observed_at(@observed_at)}
        </div>
      </div>
    </div>
    """
  end

  attr :result, :any, required: true

  def operation_error(assigns) do
    ~H"""
    <div class="alert alert-error" id="identity-management-error">
      <.dm_mdi name="alert-circle" class="h-5 w-5" />
      <span>{@result.message}</span>
    </div>
    """
  end
end

defmodule YellowDog.Console.IdentityLive.Index do
  @moduledoc "Management-backed Identity overview for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.IdentityLive.ManagementComponents
  alias YellowDog.Console.IdentityLive.ManagementSupport
  alias YellowDog.Console.Layouts
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Identity",
       subscribed_server_id: nil,
       hosts: [],
       management_error: nil,
       cached_snapshot?: false,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_hosts(socket, server_id), else: socket)}
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_hosts(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="identity-overview" class="space-y-6">
        <ManagementComponents.page_header
          title="Identity"
          subtitle="Host registry"
          server={@selected_server}
          online?={@service_online?}
        />

        <ManagementComponents.offline_snapshot
          :if={@cached_snapshot?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error :if={@management_error} result={@management_error} />

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <.card>
            <div class="text-sm text-on-surface-variant">Registered hosts</div>
            <div class="text-3xl font-bold">{length(@hosts)} total</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Approved</div>
            <div class="text-3xl font-bold text-success">{count_state(@hosts, "approved")}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Pending</div>
            <div class="text-3xl font-bold text-warning">{count_state(@hosts, "pending")}</div>
          </.card>
        </div>

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-5">
          <.link
            navigate={ServicePaths.server_path(@selected_server.id, :identity_hosts)}
            class="card bg-surface-container-low p-4 hover:bg-surface-container"
          >
            <span class="font-semibold">Hosts</span>
          </.link>
          <.link
            navigate={ServicePaths.server_path(@selected_server.id, :identity_approvals)}
            class="card bg-surface-container-low p-4 hover:bg-surface-container"
          >
            <span class="font-semibold">Approvals</span>
          </.link>
          <.link
            navigate={ServicePaths.server_path(@selected_server.id, :identity_tokens)}
            class="card bg-surface-container-low p-4 hover:bg-surface-container"
          >
            <span class="font-semibold">Tokens</span>
          </.link>
          <.link
            navigate={ServicePaths.server_path(@selected_server.id, :identity_policies)}
            class="card bg-surface-container-low p-4 hover:bg-surface-container"
          >
            <span class="font-semibold">Policies</span>
          </.link>
          <.link
            navigate={ServicePaths.server_path(@selected_server.id, :identity_audit)}
            class="card bg-surface-container-low p-4 hover:bg-surface-container"
          >
            <span class="font-semibold">Audit</span>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_hosts(socket, server_id) do
    result = ServerManagement.identity_hosts_list(server_id)

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — Identity",
      hosts: ManagementSupport.items(result),
      management_error: ManagementSupport.error(result),
      cached_snapshot?: ManagementSupport.cached?(result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(result, socket.assigns.selected_server.last_seen_at)
    )
  end

  defp count_state(hosts, state), do: Enum.count(hosts, &(&1["state"] == state))
end
