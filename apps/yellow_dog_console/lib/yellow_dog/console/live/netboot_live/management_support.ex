defmodule YellowDog.Console.NetbootLive.ManagementSupport do
  @moduledoc false

  alias Phoenix.LiveView
  alias YellowDog.Console.ManagementResult
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest

  def subscribe(socket, server_id) do
    if Phoenix.LiveView.connected?(socket) and socket.assigns[:subscribed_server_id] != server_id do
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

  def unavailable(socket, message) do
    LiveView.put_flash(socket, :error, message)
  end

  def command_options(expected_revision) do
    [expected_revision: expected_revision, idempotency_key: Ecto.UUID.generate()]
  end

  def digest(nil), do: nil

  def digest(item) when is_map(item) do
    case Digest.calculate(item) do
      {:ok, digest} -> digest
      _error -> nil
    end
  end

  def find_digest(items, finder) when is_function(finder, 1) do
    items
    |> Enum.find(finder)
    |> digest()
  end

  def exact_revision(items, finder, noun) do
    case find_digest(items, finder) do
      revision when is_binary(revision) -> {:ok, revision}
      _missing -> {:error, "#{noun} is not present in the selected Server snapshot"}
    end
  end

  def finish(socket, %ManagementResult{status: :ok} = result, message) do
    socket
    |> Phoenix.Component.assign(:operation_result, result)
    |> LiveView.put_flash(:info, message)
  end

  def finish(socket, %ManagementResult{} = result, _message) do
    socket
    |> Phoenix.Component.assign(:operation_result, result)
    |> LiveView.put_flash(:error, result.message)
  end

  def value(%ManagementResult{status: :ok, value: value}, _default), do: value
  def value(_result, default), do: default
  def items(result), do: result |> value(%{}) |> Map.get("items", [])

  def first_error(results) do
    Enum.find_value(results, fn
      %ManagementResult{status: :error} = result -> result
      _result -> nil
    end)
  end

  def cached_observed_at(results, fallback) do
    Enum.find_value(results, fallback, fn
      %ManagementResult{source: :cache, observed_at: observed_at} -> observed_at
      _result -> nil
    end)
  end

  def cached?(results), do: Enum.any?(results, &match?(%ManagementResult{source: :cache}, &1))
  def error_result?(%ManagementResult{status: :error}), do: true
  def error_result?(_result), do: false

  def csv(value) when value in [nil, ""], do: []

  def csv(value) do
    value
    |> String.split([",", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def format_observed_at(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  def format_observed_at(value) when is_binary(value), do: value
  def format_observed_at(_value), do: "unknown"
end

defmodule YellowDog.Console.NetbootLive.ManagementComponents do
  @moduledoc false

  use YellowDog.Console, :html

  alias YellowDog.Console.NetbootLive.ManagementSupport

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
    <div class="alert alert-warning" id="offline-snapshot">
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
    <div class="alert alert-error" id="management-operation-error">
      <.dm_mdi name="alert-circle" class="h-5 w-5" />
      <div>{@result.message}</div>
    </div>
    """
  end

  attr :message, :string, required: true

  def unavailable(assigns) do
    ~H"""
    <div class="alert alert-info" id="mutation-unavailable">
      <.dm_mdi name="information-outline" class="h-5 w-5" />
      <div>{@message}</div>
    </div>
    """
  end
end
