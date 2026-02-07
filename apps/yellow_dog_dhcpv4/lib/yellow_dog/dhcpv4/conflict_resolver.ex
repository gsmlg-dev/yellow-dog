defmodule YellowDog.Dhcpv4.ConflictResolver do
  @moduledoc """
  Handles IP address conflict detection and automatic reassignment.

  When a client sends a DECLINE message (indicating an IP conflict),
  this module:
  1. Marks the conflicted address as quarantined
  2. Logs the conflict with client identifier
  3. Automatically assigns a new address from the pool
  4. Tracks conflict count for monitoring

  ## Quarantine

  Conflicted addresses are temporarily unavailable for a configurable
  quarantine period (default: 1 hour) to prevent immediate reuse.

  ## Telemetry Events

  - `[:yellow_dog, :dhcpv4, :conflict, :detected]` - Conflict reported
  - `[:yellow_dog, :dhcpv4, :conflict, :reassigned]` - New address assigned
  - `[:yellow_dog, :dhcpv4, :conflict, :quarantine_expired]` - Address available again
  """

  use GenServer

  require Logger

  alias YellowDog.Dhcpv4.{AddressPool, LeaseManager, LeaseStorage}

  # Default quarantine time: 1 hour
  @default_quarantine_time 3600
  # Check quarantine expiration every minute
  @quarantine_check_interval 60_000

  @type ip_address :: AddressPool.ip_address()
  @type mac_address :: binary()

  @type conflict_record :: %{
          ip_address: ip_address(),
          client_mac: mac_address(),
          pool_name: String.t(),
          conflict_count: non_neg_integer(),
          quarantined_at: integer(),
          expires_at: integer()
        }

  # Client API

  @doc """
  Starts the ConflictResolver GenServer.

  ## Options
  - `quarantine_time` - Time in seconds to quarantine conflicted IPs (default: 3600)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reports an IP address conflict and attempts reassignment.

  Called when a DHCPDECLINE message is received.

  ## Parameters
  - `ip` - The conflicted IP address
  - `mac` - Client MAC address that reported the conflict
  - `pool_name` - Pool the IP was allocated from

  ## Returns
  - `{:ok, new_ip}` - Successfully reassigned to new address
  - `{:error, :pool_exhausted}` - No available addresses for reassignment
  """
  @spec handle_conflict(ip_address(), mac_address(), String.t()) ::
          {:ok, ip_address()} | {:error, term()}
  def handle_conflict(ip, mac, pool_name) do
    GenServer.call(__MODULE__, {:handle_conflict, ip, mac, pool_name})
  end

  @doc """
  Checks if an IP address is currently quarantined.

  ## Parameters
  - `ip` - IP address to check

  ## Returns
  - `true` if address is quarantined
  - `false` if address is available
  """
  @spec quarantined?(ip_address()) :: boolean()
  def quarantined?(ip) do
    GenServer.call(__MODULE__, {:quarantined?, ip})
  end

  @doc """
  Gets all currently quarantined IP addresses.

  ## Returns
  - List of conflict records
  """
  @spec list_quarantined() :: [conflict_record()]
  def list_quarantined do
    GenServer.call(__MODULE__, :list_quarantined)
  end

  @doc """
  Gets conflict statistics.

  ## Returns
  - Map with conflict stats
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Manually releases an IP from quarantine.

  ## Parameters
  - `ip` - IP address to release

  ## Returns
  - `:ok`
  """
  @spec release_quarantine(ip_address()) :: :ok
  def release_quarantine(ip) do
    GenServer.call(__MODULE__, {:release_quarantine, ip})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    quarantine_time = Keyword.get(opts, :quarantine_time, @default_quarantine_time)

    # Schedule periodic quarantine check
    schedule_quarantine_check()

    state = %{
      quarantined: %{},
      quarantine_time: quarantine_time,
      total_conflicts: 0,
      total_reassignments: 0
    }

    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :conflict_resolver, :started],
      %{count: 1},
      %{quarantine_time: quarantine_time}
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:handle_conflict, ip, mac, pool_name}, _from, state) do
    now = System.system_time(:second)

    # Get existing conflict record or create new one
    existing = Map.get(state.quarantined, ip)
    conflict_count = if existing, do: existing.conflict_count + 1, else: 1

    # Create conflict record
    conflict_record = %{
      ip_address: ip,
      client_mac: mac,
      pool_name: pool_name,
      conflict_count: conflict_count,
      quarantined_at: now,
      expires_at: now + state.quarantine_time
    }

    # Update quarantine map
    new_quarantined = Map.put(state.quarantined, ip, conflict_record)

    # Emit telemetry for conflict detection
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :conflict, :detected],
      %{count: 1, conflict_count: conflict_count},
      %{ip_address: ip, client_mac: format_mac(mac), pool_name: pool_name}
    )

    # Log warning for conflicts
    Logger.warning("[DHCPv4] IP conflict detected",
      ip_address: format_ip(ip),
      client_mac: format_mac(mac),
      pool: pool_name,
      conflict_count: conflict_count
    )

    # Mark the lease as declined
    LeaseManager.decline_ip(ip, mac)

    # Attempt to reassign a new IP
    result = attempt_reassignment(mac, pool_name, new_quarantined)

    new_state = %{
      state
      | quarantined: new_quarantined,
        total_conflicts: state.total_conflicts + 1,
        total_reassignments:
          if(match?({:ok, _}, result),
            do: state.total_reassignments + 1,
            else: state.total_reassignments
          )
    }

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:quarantined?, ip}, _from, state) do
    now = System.system_time(:second)

    result =
      case Map.get(state.quarantined, ip) do
        nil -> false
        record -> record.expires_at > now
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_quarantined, _from, state) do
    now = System.system_time(:second)

    # Filter out expired quarantines
    active =
      state.quarantined
      |> Map.values()
      |> Enum.filter(fn record -> record.expires_at > now end)

    {:reply, active, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    now = System.system_time(:second)

    active_quarantines =
      state.quarantined
      |> Map.values()
      |> Enum.count(fn record -> record.expires_at > now end)

    stats = %{
      total_conflicts: state.total_conflicts,
      total_reassignments: state.total_reassignments,
      active_quarantines: active_quarantines,
      quarantine_time_seconds: state.quarantine_time
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:release_quarantine, ip}, _from, state) do
    new_quarantined = Map.delete(state.quarantined, ip)

    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :conflict, :quarantine_released],
      %{count: 1},
      %{ip_address: ip}
    )

    {:reply, :ok, %{state | quarantined: new_quarantined}}
  end

  @impl true
  def handle_info(:check_quarantine, state) do
    now = System.system_time(:second)

    # Find and remove expired quarantines
    {expired, active} =
      Enum.split_with(state.quarantined, fn {_ip, record} ->
        record.expires_at <= now
      end)

    # Emit telemetry for expired quarantines
    Enum.each(expired, fn {ip, _record} ->
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :conflict, :quarantine_expired],
        %{count: 1},
        %{ip_address: ip}
      )
    end)

    # Schedule next check
    schedule_quarantine_check()

    {:noreply, %{state | quarantined: Map.new(active)}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp attempt_reassignment(mac, pool_name, quarantined) do
    # Get quarantined IPs to exclude from allocation
    quarantined_ips =
      quarantined
      |> Map.keys()
      |> MapSet.new()

    # Get already allocated IPs
    allocated_ips = LeaseStorage.get_allocated_ips()

    # Combine to get unavailable IPs
    unavailable_ips = MapSet.union(allocated_ips, quarantined_ips)

    # Get pool configuration
    case LeaseManager.get_pool_config(pool_name) do
      {:ok, pool} ->
        case AddressPool.get_available_ip(pool, unavailable_ips, mac) do
          {:ok, new_ip} ->
            # Allocate the new lease
            case LeaseManager.allocate_lease(mac, new_ip, nil, pool_name) do
              {:ok, lease} ->
                :telemetry.execute(
                  [:yellow_dog, :dhcpv4, :conflict, :reassigned],
                  %{count: 1},
                  %{
                    client_mac: format_mac(mac),
                    new_ip: format_ip(new_ip),
                    pool_name: pool_name
                  }
                )

                Logger.info("[DHCPv4] Conflict resolved",
                  client_mac: format_mac(mac),
                  new_ip: format_ip(lease.ip_address)
                )

                {:ok, new_ip}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, :pool_exhausted} ->
            Logger.error("[DHCPv4] Cannot reassign after conflict: pool exhausted",
              pool: pool_name
            )

            {:error, :pool_exhausted}
        end

      {:error, :pool_not_found} ->
        {:error, :pool_not_found}
    end
  end

  defp schedule_quarantine_check do
    Process.send_after(self(), :check_quarantine, @quarantine_check_interval)
  end

  defp format_mac(<<a, b, c, d, e, f, _rest::binary>>) do
    # Handle 6+ byte MAC addresses (e.g., 16-byte chaddr field)
    [a, b, c, d, e, f]
    |> Enum.map(fn b -> b |> Integer.to_string(16) |> String.pad_leading(2, "0") end)
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_mac(mac) when is_binary(mac) and byte_size(mac) < 6, do: inspect(mac)
  defp format_mac(_), do: "UNKNOWN"

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(_), do: "UNKNOWN"
end
