defmodule YellowDogIdentity.Trust.DHCP.LeaseCache do
  @moduledoc """
  Maintains a time-windowed view of active DHCP leases by subscribing to
  telemetry events from the DHCP apps.

  This GenServer listens for lease commit/release/expire events and maintains
  an ETS table for fast IP→lease lookups during registration verification.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @cleanup_interval :timer.minutes(5)

  @type lease_entry :: %{
          mac: String.t(),
          ip: :inet.ip_address(),
          hostname: String.t() | nil,
          fingerprint_class: String.t() | nil,
          lease_start: integer(),
          lease_duration: non_neg_integer(),
          interface: String.t() | nil
        }

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Looks up a lease by IP address.
  """
  @spec lookup(:inet.ip_address()) :: {:ok, lease_entry()} | :not_found
  def lookup(ip) do
    lookup(ip, __MODULE__)
  end

  @spec lookup(:inet.ip_address(), atom()) :: {:ok, lease_entry()} | :not_found
  def lookup(ip, table) do
    case :ets.lookup(table, ip) do
      [{^ip, entry}] -> {:ok, entry}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Manually inserts a lease entry (for testing).
  """
  @spec put(atom(), :inet.ip_address(), lease_entry()) :: true
  def put(table \\ @table, ip, entry) do
    :ets.insert(table, {ip, entry})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    table =
      if Keyword.get(opts, :name) do
        :ets.new(Keyword.get(opts, :name), [:set, :public, :named_table])
      else
        :ets.new(@table, [:set, :public, :named_table])
      end

    # Attach telemetry handlers for DHCP lease events
    attach_telemetry_handlers()

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)

    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_leases(state.table)
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("#{__MODULE__} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Telemetry handlers

  defp attach_telemetry_handlers do
    events = [
      [:yellow_dog, :dhcp, :lease, :commit],
      [:yellow_dog, :dhcp, :lease, :release],
      [:yellow_dog, :dhcp, :lease, :expire],
      # DHCPv4-specific events
      [:yellow_dog, :dhcpv4, :lease, :allocated],
      [:yellow_dog, :dhcpv4, :lease, :renewed]
    ]

    :telemetry.attach_many(
      "identity-lease-cache",
      events,
      &__MODULE__.handle_telemetry_event/4,
      %{table: @table}
    )
  end

  @doc false
  def handle_telemetry_event([:yellow_dog, :dhcp, :lease, :commit], _measurements, metadata, config) do
    handle_lease_commit(metadata, config.table)
  end

  def handle_telemetry_event([:yellow_dog, :dhcpv4, :lease, :allocated], _measurements, metadata, config) do
    handle_lease_commit(metadata, config.table)
  end

  def handle_telemetry_event([:yellow_dog, :dhcpv4, :lease, :renewed], _measurements, metadata, config) do
    handle_lease_commit(metadata, config.table)
  end

  def handle_telemetry_event([:yellow_dog, :dhcp, :lease, action], _measurements, metadata, config)
      when action in [:release, :expire] do
    ip = Map.get(metadata, :ip) || Map.get(metadata, :released_ip) || Map.get(metadata, :expired_ip)

    if ip do
      :ets.delete(config.table, ip)
    end
  end

  def handle_telemetry_event(_event, _measurements, _metadata, _config), do: :ok

  defp handle_lease_commit(metadata, table) do
    ip = Map.get(metadata, :ip) || Map.get(metadata, :client_ip)

    if ip do
      entry = %{
        mac: to_string(Map.get(metadata, :mac) || Map.get(metadata, :mac_address, "")),
        ip: ip,
        hostname: Map.get(metadata, :hostname) || Map.get(metadata, :client_hostname),
        fingerprint_class: Map.get(metadata, :fingerprint_class),
        lease_start: System.monotonic_time(:second),
        lease_duration: Map.get(metadata, :lease_duration) || Map.get(metadata, :lease_time, 3600),
        interface: Map.get(metadata, :interface) |> to_string_or_nil()
      }

      :ets.insert(table, {ip, entry})
    end
  end

  defp cleanup_expired_leases(table) do
    now = System.monotonic_time(:second)

    :ets.foldl(
      fn {ip, entry}, acc ->
        if now - entry.lease_start > entry.lease_duration do
          :ets.delete(table, ip)
        end

        acc
      end,
      :ok,
      table
    )
  rescue
    ArgumentError -> :ok
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(val), do: to_string(val)
end
