defmodule YellowDog.Console.DashboardLive do
  @moduledoc """
  Management-backed dashboard for one explicitly selected Server runtime.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest

  @refresh_interval 5_000
  @valid_services ~w(dns mdns dhcpv4 dhcpv6 netboot identity)
  @service_info %{
    "dns" => %{name: "DNS", description: "Domain Name Service"},
    "dhcpv4" => %{name: "DHCPv4", description: "DHCP IPv4 Service"},
    "dhcpv6" => %{name: "DHCPv6", description: "DHCP IPv6 Service"},
    "mdns" => %{name: "mDNS", description: "Multicast DNS"},
    "netboot" => %{name: "Netboot", description: "Network Boot Service"},
    "identity" => %{name: "Identity", description: "Host Identity Service"}
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_interval, self(), :refresh_services)

    {:ok,
     socket
     |> assign(:page_title, "Server Dashboard")
     |> assign(:subscribed_server_id, nil)
     |> assign(:services, fallback_services())
     |> assign(:health, %{"status" => "unknown", "checks" => []})
     |> assign(:stats, %{"requests" => 0, "errors" => 0})
     |> assign(:management_error, nil)
     |> assign(:cached_observed_at, nil)
     |> assign(:commands_enabled?, socket.assigns.service_online?)}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_dashboard(socket), else: socket)}
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> refresh_selected_server(server_id)
     |> load_dashboard()}
  end

  def handle_info(:refresh_services, socket), do: {:noreply, load_dashboard(socket)}

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_dashboard(socket)}

  @impl true
  def handle_event(action, %{"service" => service}, socket)
      when action in ["start_service", "stop_service"] and service in @valid_services do
    if socket.assigns.commands_enabled? do
      {:noreply, control_service(socket, action, service)}
    else
      {:noreply, put_flash(socket, :error, "The selected Server is offline")}
    end
  end

  @impl true
  def handle_event(action, _params, socket)
      when action in ["start_service", "stop_service"] do
    {:noreply, put_flash(socket, :error, "Invalid service name")}
  end

  defp subscribe(socket, server_id) do
    if connected?(socket) and socket.assigns[:subscribed_server_id] != server_id do
      if old_id = socket.assigns[:subscribed_server_id] do
        Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "management:server:#{old_id}")
      end

      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "management:server:#{server_id}")
    end

    assign(socket, :subscribed_server_id, server_id)
  end

  defp refresh_selected_server(socket, server_id) do
    case ManagementCore.get_server(server_id) do
      {:ok, server} ->
        assign(socket,
          selected_server: server,
          service_online?: server.status in [:online, "online"],
          snapshot_observed_at: server.last_seen_at
        )

      _error ->
        socket
    end
  end

  defp load_dashboard(socket) do
    server_id = socket.assigns.selected_server.id
    services = ServerManagement.runtime_services_list(server_id)
    health = ServerManagement.runtime_health_get(server_id)
    stats = ServerManagement.runtime_stats_get(server_id)
    results = [services, health, stats]

    assign(socket,
      services: service_items(services),
      health: result_value(health, %{"status" => "unknown", "checks" => []}),
      stats: result_value(stats, %{"requests" => 0, "errors" => 0}),
      management_error: first_error(results),
      cached_observed_at: latest_observed_at(results),
      commands_enabled?: socket.assigns.service_online? and services.status == :ok
    )
  end

  defp control_service(socket, action, service) do
    payload = %{"service" => service}

    opts = [
      expected_revision: service_revision(socket.assigns.services, service),
      idempotency_key: Ecto.UUID.generate()
    ]

    result =
      case action do
        "start_service" ->
          ServerManagement.runtime_services_start(
            socket.assigns.selected_server.id,
            payload,
            opts
          )

        "stop_service" ->
          ServerManagement.runtime_services_stop(socket.assigns.selected_server.id, payload, opts)
      end

    case result do
      %ManagementResult{status: :ok, value: %{"state" => state}} ->
        socket
        |> assign(:services, update_service(socket.assigns.services, service, state))
        |> put_flash(:info, "#{service_name(service)} is now #{state}")

      %ManagementResult{status: :error, message: message} ->
        put_flash(socket, :error, message)
    end
  end

  defp service_items(%ManagementResult{status: :ok, value: %{"items" => items}})
       when is_list(items) do
    by_service =
      Enum.reduce(items, %{}, fn
        %{"service" => service, "state" => state}, acc
        when service in @valid_services and state in ["running", "stopped", "failed"] ->
          Map.put(acc, service, state)

        _invalid, acc ->
          acc
      end)

    Enum.map(@valid_services, &service_item(&1, Map.get(by_service, &1, "unknown")))
  end

  defp service_items(_result), do: fallback_services()

  defp fallback_services, do: Enum.map(@valid_services, &service_item(&1, "unknown"))

  defp service_item(service, state) do
    info = Map.fetch!(@service_info, service)
    resource = %{"service" => service, "state" => state}

    %{
      key: service,
      name: info.name,
      description: info.description,
      state: state,
      running: state == "running",
      revision: resource_revision(resource)
    }
  end

  defp update_service(services, service, state) do
    Enum.map(services, fn item ->
      if item.key == service do
        resource = %{"service" => service, "state" => state}
        %{item | state: state, running: state == "running", revision: resource_revision(resource)}
      else
        item
      end
    end)
  end

  defp service_revision(services, service) do
    case Enum.find(services, &(&1.key == service)) do
      %{revision: revision} when is_binary(revision) -> revision
      _missing -> nil
    end
  end

  defp resource_revision(resource) do
    case Digest.calculate(resource) do
      {:ok, revision} -> revision
      {:error, _error} -> nil
    end
  end

  defp result_value(%ManagementResult{status: :ok, value: value}, _fallback), do: value
  defp result_value(_result, fallback), do: fallback

  defp first_error(results) do
    Enum.find_value(results, fn
      %ManagementResult{status: :error, message: message} -> message
      _result -> nil
    end)
  end

  defp latest_observed_at(results) do
    results
    |> Enum.flat_map(fn
      %ManagementResult{observed_at: %DateTime{} = observed_at} -> [observed_at]
      _result -> []
    end)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp service_name(service), do: @service_info |> Map.fetch!(service) |> Map.fetch!(:name)

  defp server_service_path(server_id, "dns"), do: ServicePaths.server_path(server_id, :dns)
  defp server_service_path(server_id, "mdns"), do: ServicePaths.server_path(server_id, :mdns)
  defp server_service_path(server_id, "dhcpv4"), do: ServicePaths.server_path(server_id, :dhcpv4)
  defp server_service_path(server_id, "dhcpv6"), do: ServicePaths.server_path(server_id, :dhcpv6)

  defp server_service_path(server_id, "netboot"),
    do: ServicePaths.server_path(server_id, :netboot)

  defp server_service_path(server_id, "identity"),
    do: ServicePaths.server_path(server_id, :identity)

  defp server_quick_actions(server_id) do
    [
      {"DNS Management", ServicePaths.server_path(server_id, :dns)},
      {"DHCPv4 Server", ServicePaths.server_path(server_id, :dhcpv4)},
      {"mDNS Discovery", ServicePaths.server_path(server_id, :mdns)},
      {"Netboot", ServicePaths.server_path(server_id, :netboot)},
      {"Identity", ServicePaths.server_path(server_id, :identity)},
      {"Configuration", ServicePaths.server_path(server_id, :settings)}
    ]
  end

  defp service_state_label(state) when is_binary(state),
    do: state |> String.replace("_", " ") |> String.capitalize()

  defp service_state_label(_state), do: "Unknown"

  defp service_state_color("running"), do: "success"
  defp service_state_color("failed"), do: "error"
  defp service_state_color("stopped"), do: "neutral"
  defp service_state_color(_state), do: "ghost"

  defp health_color("healthy"), do: "success"
  defp health_color("degraded"), do: "warning"
  defp health_color("unhealthy"), do: "error"
  defp health_color(_status), do: "ghost"
end
