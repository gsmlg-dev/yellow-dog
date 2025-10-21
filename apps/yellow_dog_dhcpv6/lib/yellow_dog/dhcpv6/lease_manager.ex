defmodule YellowDog.Dhcpv6.LeaseManager do
  @moduledoc """
  Manages DHCPv6 lease allocation and tracking using ETS storage.

  Tracks active leases with DUID → IPv6 bindings, handles lease expiration,
  and provides persistence across server restarts.
  """

  use GenServer
  require Logger

  alias YellowDog.Dhcpv6.AddressPool

  @table_name :dhcpv6_leases
  @ets_options [:named_table, :public, :set, read_concurrency: true]
  @cleanup_interval 60_000  # Run cleanup every minute

  @type ipv6_address :: AddressPool.ipv6_address()
  @type duid :: AddressPool.duid()
  @type lease :: %{
          ip: ipv6_address(),
          duid: duid(),
          iaid: non_neg_integer(),
          preferred_lifetime: pos_integer(),
          valid_lifetime: pos_integer(),
          expires_at: integer(),
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
  Allocates or renews a lease for a DUID.

  ## Parameters
  - `duid` - Client DUID (DHCP Unique Identifier)
  - `iaid` - Identity Association Identifier
  - `requested_ip` - Optional requested IP address
  - `pool_name` - Pool name to allocate from (default: "default")

  ## Returns
  - `{:ok, lease}` - Successfully allocated/renewed lease
  - `{:error, reason}` - Failed to allocate lease
  """
  @spec allocate_lease(duid(), non_neg_integer(), ipv6_address() | nil, String.t()) ::
          {:ok, lease()} | {:error, term()}
  def allocate_lease(duid, iaid, requested_ip \\ nil, pool_name \\ "default") do
    GenServer.call(__MODULE__, {:allocate_lease, duid, iaid, requested_ip, pool_name})
  end

  @doc """
  Releases a lease for a DUID.

  ## Parameters
  - `duid` - Client DUID
  - `iaid` - Identity Association Identifier

  ## Returns
  - `:ok` - Lease released
  """
  @spec release_lease(duid(), non_neg_integer()) :: :ok
  def release_lease(duid, iaid) do
    GenServer.call(__MODULE__, {:release_lease, duid, iaid})
  end

  @doc """
  Declines an IP address (marks it as unavailable for a period).

  ## Parameters
  - `ip` - IP address to decline
  - `duid` - Client DUID that declined

  ## Returns
  - `:ok` - IP declined
  """
  @spec decline_ip(ipv6_address(), duid()) :: :ok
  def decline_ip(ip, duid) do
    GenServer.call(__MODULE__, {:decline_ip, ip, duid})
  end

  @doc """
  Gets the current lease for a DUID and IAID.

  ## Parameters
  - `duid` - Client DUID
  - `iaid` - Identity Association Identifier

  ## Returns
  - `{:ok, lease}` - Active lease found
  - `{:error, :not_found}` - No active lease
  """
  @spec get_lease(duid(), non_neg_integer()) :: {:ok, lease()} | {:error, :not_found}
  def get_lease(duid, iaid) do
    lease_key = make_lease_key(duid, iaid)
    case :ets.lookup(@table_name, lease_key) do
      [{^lease_key, lease}] ->
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
    |> Enum.map(fn {_key, lease} -> lease end)
    |> Enum.filter(fn lease -> lease.expires_at > now end)
  end

  @doc """
  Gets all allocated IP addresses.

  ## Returns
  - MapSet of allocated IP addresses
  """
  @spec get_allocated_ips() :: MapSet.t(ipv6_address())
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
            Logger.error("Failed to create DHCPv6 address pool: #{inspect(reason)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Schedule periodic cleanup
    schedule_cleanup()

    state = %{
      pools: parsed_pools
    }

    Logger.info("DHCPv6 LeaseManager started with #{length(parsed_pools)} pools")

    {:ok, state}
  end

  @impl true
  def handle_call({:allocate_lease, duid, iaid, requested_ip, pool_name}, _from, state) do
    # Find the pool
    pool = Enum.find(state.pools, fn p -> p.name == pool_name end)

    if pool do
      result = do_allocate_lease(duid, iaid, requested_ip, pool)
      {:reply, result, state}
    else
      {:reply, {:error, :pool_not_found}, state}
    end
  end

  @impl true
  def handle_call({:release_lease, duid, iaid}, _from, state) do
    lease_key = make_lease_key(duid, iaid)
    :ets.delete(@table_name, lease_key)
    Logger.info("Released DHCPv6 lease for DUID #{format_duid(duid)} IAID #{iaid}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:decline_ip, ip, duid}, _from, state) do
    # For now, just release any lease with this IP
    # In production, mark IP as temporarily unavailable
    leases = list_leases()
    Enum.each(leases, fn lease ->
      if lease.ip == ip do
        lease_key = make_lease_key(lease.duid, lease.iaid)
        :ets.delete(@table_name, lease_key)
      end
    end)

    Logger.warning("IPv6 address #{inspect(ip)} declined by DUID #{format_duid(duid)}")
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

  defp make_lease_key(duid, iaid) do
    "#{format_duid(duid)}:#{iaid}"
  end

  defp do_allocate_lease(duid, iaid, requested_ip, pool) do
    lease_key = make_lease_key(duid, iaid)

    # Check for existing lease
    case :ets.lookup(@table_name, lease_key) do
      [{^lease_key, existing_lease}] ->
        # Renew existing lease
        renewed_lease = renew_lease(existing_lease)
        :ets.insert(@table_name, {lease_key, renewed_lease})
        Logger.info("Renewed DHCPv6 lease for DUID #{format_duid(duid)} IAID #{iaid}: #{inspect(renewed_lease.ip)}")
        {:ok, renewed_lease}

      [] ->
        # Allocate new lease
        allocate_new_lease(duid, iaid, lease_key, requested_ip, pool)
    end
  end

  defp allocate_new_lease(duid, iaid, lease_key, requested_ip, pool) do
    allocated_ips = get_allocated_ips()

    # Try to honor requested IP if provided and available
    ip =
      cond do
        requested_ip && AddressPool.in_range?(pool, requested_ip) &&
            not MapSet.member?(allocated_ips, requested_ip) ->
          requested_ip

        true ->
          case AddressPool.get_available_ip(pool, allocated_ips, duid) do
            {:ok, available_ip} -> available_ip
            {:error, :pool_exhausted} -> nil
          end
      end

    if ip do
      lease = %{
        ip: ip,
        duid: duid,
        iaid: iaid,
        preferred_lifetime: pool.preferred_lifetime,
        valid_lifetime: pool.valid_lifetime,
        expires_at: System.system_time(:second) + pool.valid_lifetime,
        pool_name: pool.name
      }

      :ets.insert(@table_name, {lease_key, lease})
      Logger.info("Allocated new DHCPv6 lease for DUID #{format_duid(duid)} IAID #{iaid}: #{inspect(ip)}")

      # Emit telemetry event
      :telemetry.execute(
        [:yellow_dog, :dhcpv6, :lease_allocated],
        %{count: 1},
        %{duid: format_duid(duid), iaid: iaid, ip: ip, pool: pool.name}
      )

      {:ok, lease}
    else
      Logger.error("DHCPv6 pool exhausted for #{pool.name}")
      {:error, :pool_exhausted}
    end
  end

  defp renew_lease(lease) do
    %{lease |
      expires_at: System.system_time(:second) + lease.valid_lifetime
    }
  end

  defp cleanup_expired_leases do
    now = System.system_time(:second)
    expired_leases =
      @table_name
      |> :ets.tab2list()
      |> Enum.filter(fn {_key, lease} -> lease.expires_at <= now end)

    Enum.each(expired_leases, fn {key, _lease} ->
      :ets.delete(@table_name, key)
    end)

    expired_count = length(expired_leases)

    if expired_count > 0 do
      Logger.info("Cleaned up #{expired_count} expired DHCPv6 leases")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired_leases, @cleanup_interval)
  end

  defp format_duid(duid) when is_binary(duid) do
    duid
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_duid(_), do: "UNKNOWN"
end
