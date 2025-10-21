defmodule YellowDog.Dhcpv4.LeaseManager do
  @moduledoc """
  Manages DHCP lease allocation and tracking using ETS storage.

  Tracks active leases with MAC → IP bindings, handles lease expiration,
  and provides persistence across server restarts.
  """

  use GenServer
  require Logger

  alias YellowDog.Dhcpv4.AddressPool

  @table_name :dhcpv4_leases
  @ets_options [:named_table, :public, :set, read_concurrency: true]
  @cleanup_interval 60_000  # Run cleanup every minute

  @type ip_address :: AddressPool.ip_address()
  @type mac_address :: AddressPool.mac_address()
  @type lease :: %{
          ip: ip_address(),
          mac: mac_address(),
          hostname: String.t() | nil,
          expires_at: integer(),
          lease_time: pos_integer(),
          pool_name: String.t()
        }

  # Client API

  @doc """
  Starts the LeaseManager GenServer.

  ## Options
  - `pools` - List of address pool configurations

  ## Returns
  - `{:ok, pid}` - Successfully started
  - `{:error, reason}` - Failed to start
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Allocates or renews a lease for a MAC address.

  ## Parameters
  - `mac` - Client MAC address (6 bytes binary)
  - `requested_ip` - Optional requested IP address
  - `hostname` - Optional client hostname
  - `pool_name` - Pool name to allocate from (default: "default")

  ## Returns
  - `{:ok, lease}` - Successfully allocated/renewed lease
  - `{:error, reason}` - Failed to allocate lease
  """
  @spec allocate_lease(mac_address(), ip_address() | nil, String.t() | nil, String.t()) ::
          {:ok, lease()} | {:error, term()}
  def allocate_lease(mac, requested_ip \\ nil, hostname \\ nil, pool_name \\ "default") do
    GenServer.call(__MODULE__, {:allocate_lease, mac, requested_ip, hostname, pool_name})
  end

  @doc """
  Releases a lease for a MAC address.

  ## Parameters
  - `mac` - Client MAC address

  ## Returns
  - `:ok` - Lease released
  """
  @spec release_lease(mac_address()) :: :ok
  def release_lease(mac) do
    GenServer.call(__MODULE__, {:release_lease, mac})
  end

  @doc """
  Declines an IP address (marks it as unavailable for a period).

  ## Parameters
  - `ip` - IP address to decline
  - `mac` - Client MAC address that declined

  ## Returns
  - `:ok` - IP declined
  """
  @spec decline_ip(ip_address(), mac_address()) :: :ok
  def decline_ip(ip, mac) do
    GenServer.call(__MODULE__, {:decline_ip, ip, mac})
  end

  @doc """
  Gets the current lease for a MAC address.

  ## Parameters
  - `mac` - Client MAC address

  ## Returns
  - `{:ok, lease}` - Active lease found
  - `{:error, :not_found}` - No active lease
  """
  @spec get_lease(mac_address()) :: {:ok, lease()} | {:error, :not_found}
  def get_lease(mac) do
    case :ets.lookup(@table_name, format_mac(mac)) do
      [{_mac, lease}] ->
        # Check if lease is expired
        if lease.expires_at > System.system_time(:second) do
          {:ok, lease}
        else
          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets all active leases.

  ## Returns
  - List of active leases
  """
  @spec list_leases() :: [lease()]
  def list_leases do
    now = System.system_time(:second)

    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_mac, lease} -> lease end)
    |> Enum.filter(fn lease -> lease.expires_at > now end)
  end

  @doc """
  Gets all allocated IP addresses.

  ## Returns
  - MapSet of allocated IP addresses
  """
  @spec get_allocated_ips() :: MapSet.t(ip_address())
  def get_allocated_ips do
    list_leases()
    |> Enum.map(& &1.ip)
    |> MapSet.new()
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # Initialize ETS table
    init_table()

    # Extract pools from options
    pools = Keyword.get(opts, :pools, [])

    # Parse pools into AddressPool configs
    parsed_pools =
      Enum.map(pools, fn pool_config ->
        case AddressPool.new(pool_config) do
          {:ok, pool} -> pool
          {:error, reason} ->
            Logger.error("Failed to create address pool: #{inspect(reason)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Schedule periodic cleanup
    schedule_cleanup()

    state = %{
      pools: parsed_pools
    }

    Logger.info("LeaseManager started with #{length(parsed_pools)} pools")

    {:ok, state}
  end

  @impl true
  def handle_call({:allocate_lease, mac, requested_ip, hostname, pool_name}, _from, state) do
    # Find the pool
    pool = Enum.find(state.pools, fn p -> p.name == pool_name end)

    if pool do
      result = do_allocate_lease(mac, requested_ip, hostname, pool)
      {:reply, result, state}
    else
      {:reply, {:error, :pool_not_found}, state}
    end
  end

  @impl true
  def handle_call({:release_lease, mac}, _from, state) do
    mac_key = format_mac(mac)
    :ets.delete(@table_name, mac_key)
    Logger.info("Released lease for MAC #{mac_key}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:decline_ip, ip, mac}, _from, state) do
    # For now, just release the lease
    # In a production system, you might want to mark this IP as temporarily unavailable
    mac_key = format_mac(mac)
    :ets.delete(@table_name, mac_key)
    Logger.warning("IP #{inspect(ip)} declined by MAC #{mac_key}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup_expired_leases, state) do
    cleanup_expired_leases()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private helper functions

  defp init_table do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, @ets_options)
    end
    :ok
  end

  defp do_allocate_lease(mac, requested_ip, hostname, pool) do
    mac_key = format_mac(mac)

    # Check for existing lease
    case :ets.lookup(@table_name, mac_key) do
      [{^mac_key, existing_lease}] ->
        # Renew existing lease
        renewed_lease = renew_lease(existing_lease, hostname)
        :ets.insert(@table_name, {mac_key, renewed_lease})
        Logger.info("Renewed lease for MAC #{mac_key}: #{inspect(renewed_lease.ip)}")
        {:ok, renewed_lease}

      [] ->
        # Allocate new lease
        allocate_new_lease(mac, mac_key, requested_ip, hostname, pool)
    end
  end

  defp allocate_new_lease(mac, mac_key, requested_ip, hostname, pool) do
    allocated_ips = get_allocated_ips()

    # Try to honor requested IP if provided and available
    ip =
      cond do
        requested_ip && AddressPool.in_range?(pool, requested_ip) &&
            not MapSet.member?(allocated_ips, requested_ip) ->
          requested_ip

        true ->
          case AddressPool.get_available_ip(pool, allocated_ips, mac) do
            {:ok, available_ip} -> available_ip
            {:error, :pool_exhausted} -> nil
          end
      end

    if ip do
      lease = %{
        ip: ip,
        mac: mac,
        hostname: hostname,
        expires_at: System.system_time(:second) + pool.lease_time,
        lease_time: pool.lease_time,
        pool_name: pool.name
      }

      :ets.insert(@table_name, {mac_key, lease})
      Logger.info("Allocated new lease for MAC #{mac_key}: #{inspect(ip)}")

      # Emit telemetry event
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :lease_allocated],
        %{count: 1},
        %{mac: mac_key, ip: ip, pool: pool.name}
      )

      {:ok, lease}
    else
      Logger.error("Pool exhausted for #{pool.name}")
      {:error, :pool_exhausted}
    end
  end

  defp renew_lease(lease, hostname) do
    %{lease | expires_at: System.system_time(:second) + lease.lease_time, hostname: hostname || lease.hostname}
  end

  defp cleanup_expired_leases do
    now = System.system_time(:second)
    expired_count =
      @table_name
      |> :ets.tab2list()
      |> Enum.filter(fn {_mac, lease} -> lease.expires_at <= now end)
      |> Enum.each(fn {mac, _lease} ->
        :ets.delete(@table_name, mac)
      end)
      |> length()

    if expired_count > 0 do
      Logger.info("Cleaned up #{expired_count} expired leases")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired_leases, @cleanup_interval)
  end

  defp format_mac(<<mac::binary-size(6)>>) do
    mac
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_mac(mac) when is_binary(mac) and byte_size(mac) == 16 do
    # Handle padded MAC address from DHCP message (16 bytes with trailing zeros)
    <<actual_mac::binary-size(6), _rest::binary>> = mac
    format_mac(actual_mac)
  end

  defp format_mac(_), do: "UNKNOWN"
end
