defmodule YellowDog.Netman.Connection.LeaseCoordinator do
  @moduledoc """
  Routes DHCP client telemetry events to Connection.FSM processes.

  Attaches to `[:yellow_dog, :dhcp_client, :lease, :*]` telemetry events
  and forwards them as messages to the appropriate FSM, looked up by
  interface name via `YellowDog.Netman.Registry`.

  ## Telemetry → FSM message mapping

      [:yellow_dog, :dhcp_client, :lease, :bound]   → {:dhcp_lease_acquired, lease_info}
      [:yellow_dog, :dhcp_client, :lease, :renewed]  → {:dhcp_lease_renewed, lease_info}
      [:yellow_dog, :dhcp_client, :lease, :expired]  → {:dhcp_lease_expired, :expired}
  """

  use GenServer

  require Logger

  @handler_id "netman-lease-coordinator"

  @telemetry_events [
    [:yellow_dog, :dhcp_client, :lease, :bound],
    [:yellow_dog, :dhcp_client, :lease, :renewed],
    [:yellow_dog, :dhcp_client, :lease, :expired]
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Detach first to handle restarts after :kill
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      @telemetry_events,
      &__MODULE__.handle_telemetry/4,
      nil
    )

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_telemetry(
        [:yellow_dog, :dhcp_client, :lease, event_type],
        measurements,
        metadata,
        _config
      ) do
    interface = Map.get(metadata, :interface)

    if interface do
      lease_info = build_lease_info(event_type, measurements, metadata)
      message = telemetry_to_fsm_message(event_type, lease_info)
      send_to_fsm(interface, message)
    end
  end

  defp telemetry_to_fsm_message(:bound, lease_info), do: {:dhcp_lease_acquired, lease_info}
  defp telemetry_to_fsm_message(:renewed, lease_info), do: {:dhcp_lease_renewed, lease_info}
  defp telemetry_to_fsm_message(:expired, _lease_info), do: {:dhcp_lease_expired, :expired}

  defp build_lease_info(_event_type, measurements, metadata) do
    %{
      ip: Map.get(metadata, :ip),
      server: Map.get(metadata, :server),
      lease_time_s: Map.get(measurements, :lease_time_s),
      dns_servers: Map.get(metadata, :dns_servers, [])
    }
  end

  defp send_to_fsm(interface, message) do
    case Registry.lookup(YellowDog.Netman.Registry, {:connection, interface}) do
      [{pid, _}] ->
        send(pid, message)

      [] ->
        Logger.debug(
          "LeaseCoordinator: no FSM for interface #{interface}, dropping #{inspect(elem(message, 0))}"
        )
    end
  end
end
