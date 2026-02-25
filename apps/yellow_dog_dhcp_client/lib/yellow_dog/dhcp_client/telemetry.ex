defmodule YellowDog.DhcpClient.Telemetry do
  @moduledoc """
  Telemetry event emission for the DHCP client.

  All events are prefixed with `[:yellow_dog, :dhcp_client]`.
  """

  @prefix [:yellow_dog, :dhcp_client]

  @doc """
  Emits a state transition event.

  Event: `[:yellow_dog, :dhcp_client, :state, :change]`
  """
  @spec state_change(String.t(), atom(), atom(), non_neg_integer()) :: :ok
  def state_change(interface, from, to, duration_ms) do
    :telemetry.execute(
      @prefix ++ [:state, :change],
      %{duration_in_state_ms: duration_ms},
      %{interface: interface, from: from, to: to}
    )
  end

  @doc """
  Emits a packet TX event.

  Event: `[:yellow_dog, :dhcp_client, :packet, :tx]`
  """
  @spec packet_tx(String.t(), atom()) :: :ok
  def packet_tx(interface, type) do
    :telemetry.execute(
      @prefix ++ [:packet, :tx],
      %{},
      %{interface: interface, type: type}
    )
  end

  @doc """
  Emits a packet RX event.

  Event: `[:yellow_dog, :dhcp_client, :packet, :rx]`
  """
  @spec packet_rx(String.t(), atom(), :inet.ip4_address()) :: :ok
  def packet_rx(interface, type, server) do
    :telemetry.execute(
      @prefix ++ [:packet, :rx],
      %{},
      %{interface: interface, type: type, server: server}
    )
  end

  @doc """
  Emits a lease bound event.

  Event: `[:yellow_dog, :dhcp_client, :lease, :bound]`
  """
  @spec lease_bound(String.t(), String.t(), String.t(), pos_integer(), non_neg_integer()) :: :ok
  def lease_bound(interface, ip, server, lease_time_s, handshake_duration_ms) do
    :telemetry.execute(
      @prefix ++ [:lease, :bound],
      %{lease_time_s: lease_time_s, handshake_duration_ms: handshake_duration_ms},
      %{interface: interface, ip: ip, server: server}
    )
  end

  @doc """
  Emits a lease renewed event.

  Event: `[:yellow_dog, :dhcp_client, :lease, :renewed]`
  """
  @spec lease_renewed(String.t(), String.t(), pos_integer()) :: :ok
  def lease_renewed(interface, ip, lease_time_s) do
    :telemetry.execute(
      @prefix ++ [:lease, :renewed],
      %{lease_time_s: lease_time_s},
      %{interface: interface, ip: ip}
    )
  end

  @doc """
  Emits a lease expired event.

  Event: `[:yellow_dog, :dhcp_client, :lease, :expired]`
  """
  @spec lease_expired(String.t(), String.t()) :: :ok
  def lease_expired(interface, ip) do
    :telemetry.execute(
      @prefix ++ [:lease, :expired],
      %{},
      %{interface: interface, ip: ip}
    )
  end

  @doc """
  Emits an OS integration event.

  Event: `[:yellow_dog, :dhcp_client, :os, :apply]`
  """
  @spec os_apply(String.t(), atom(), atom(), non_neg_integer()) :: :ok
  def os_apply(interface, action, result, duration_ms) do
    :telemetry.execute(
      @prefix ++ [:os, :apply],
      %{duration_ms: duration_ms},
      %{interface: interface, action: action, result: result}
    )
  end

  @doc """
  Returns the list of all telemetry event names emitted by this module.
  """
  @spec event_names() :: [list()]
  def event_names do
    [
      @prefix ++ [:state, :change],
      @prefix ++ [:packet, :tx],
      @prefix ++ [:packet, :rx],
      @prefix ++ [:lease, :bound],
      @prefix ++ [:lease, :renewed],
      @prefix ++ [:lease, :expired],
      @prefix ++ [:os, :apply],
      @prefix ++ [:dad, :start],
      @prefix ++ [:dad, :result]
    ]
  end
end
