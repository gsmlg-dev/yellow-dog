defmodule YellowDog.Dhcpv4.LeaseStorage do
  @moduledoc """
  Persistent lease storage using Mnesia.

  Provides a durable, transactional storage layer for DHCP leases with
  support for multiple lease states and comprehensive querying.

  ## Lease States

  - `:offered` - IP address offered to client, awaiting REQUEST
  - `:active` - Lease active and in use by client
  - `:released` - Client released the lease voluntarily
  - `:expired` - Lease exceeded its lifetime
  - `:declined` - Client declined the offered IP (conflict detected)

  ## Storage Modes

  - `:disc_copies` - Persistent storage (default for production)
  - `:ram_copies` - Memory-only storage (for testing)
  """

  require Record

  alias YellowDog.Dhcpv4.AddressPool

  @type ip_address :: AddressPool.ip_address()
  @type mac_address :: binary()
  @type client_id :: binary() | nil
  @type lease_state :: :offered | :active | :released | :expired | :declined

  @type lease :: %{
          mac_address: mac_address(),
          ip_address: ip_address(),
          pool_name: String.t(),
          state: lease_state(),
          lease_time: pos_integer(),
          expires_at: integer(),
          hostname: String.t() | nil,
          client_id: client_id(),
          created_at: integer(),
          updated_at: integer()
        }

  # Define Mnesia record
  Record.defrecord(:lease_record,
    mac_address: nil,
    ip_address: nil,
    pool_name: nil,
    state: :offered,
    lease_time: 0,
    expires_at: 0,
    hostname: nil,
    client_id: nil,
    created_at: 0,
    updated_at: 0
  )

  @table_name :dhcpv4_leases

  ## Public API

  @doc """
  Initializes the Mnesia schema and creates the leases table.

  ## Options

  - `:storage_type` - `:disc_copies` (default) or `:ram_copies`
  - `:nodes` - List of nodes to create table on (default: [node()])

  ## Returns

  - `:ok` - Successfully initialized
  - `{:error, reason}` - Failed to initialize
  """
  @spec init(keyword()) :: :ok | {:error, term()}
  def init(opts \\ []) do
    storage_type = Keyword.get(opts, :storage_type, :disc_copies)
    nodes = Keyword.get(opts, :nodes, [node()])

    with :ok <- ensure_schema_created(nodes),
         :ok <- ensure_table_created(storage_type, nodes) do
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :lease_storage, :initialized],
        %{count: 1},
        %{storage_type: storage_type, nodes: nodes}
      )

      :ok
    else
      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease_storage, :init_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        error
    end
  end

  @doc """
  Stores or updates a lease in the database.

  ## Parameters

  - `lease` - Lease map with required fields

  ## Returns

  - `{:ok, lease}` - Successfully stored
  - `{:error, reason}` - Failed to store
  """
  @spec put(lease()) :: {:ok, lease()} | {:error, term()}
  def put(lease) do
    now = System.system_time(:second)

    record =
      lease_record(
        mac_address: lease.mac_address,
        ip_address: lease.ip_address,
        pool_name: lease.pool_name,
        state: lease.state,
        lease_time: lease.lease_time,
        expires_at: lease.expires_at,
        hostname: lease[:hostname],
        client_id: lease[:client_id],
        created_at: lease[:created_at] || now,
        updated_at: now
      )

    transaction = fn ->
      :mnesia.write(@table_name, record, :write)
      record_to_map(record)
    end

    case :mnesia.transaction(transaction) do
      {:atomic, result} ->
        {:ok, result}

      {:aborted, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease_storage, :store_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Retrieves a lease by MAC address.

  ## Parameters

  - `mac_address` - Client MAC address

  ## Returns

  - `{:ok, lease}` - Lease found
  - `{:error, :not_found}` - No lease exists
  """
  @spec get(mac_address()) :: {:ok, lease()} | {:error, :not_found}
  def get(mac_address) do
    transaction = fn ->
      case :mnesia.read(@table_name, mac_address) do
        [record] -> record_to_map(record)
        [] -> nil
      end
    end

    case :mnesia.transaction(transaction) do
      {:atomic, nil} ->
        {:error, :not_found}

      {:atomic, lease} ->
        {:ok, lease}

      {:aborted, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease_storage, :read_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Retrieves a lease by IP address.

  ## Parameters

  - `ip_address` - IP address tuple

  ## Returns

  - `{:ok, lease}` - Lease found
  - `{:error, :not_found}` - No lease exists
  """
  @spec get_by_ip(ip_address()) :: {:ok, lease()} | {:error, :not_found}
  def get_by_ip(ip_address) do
    transaction = fn ->
      :mnesia.match_object(@table_name, lease_record(ip_address: ip_address, _: :_), :read)
    end

    case :mnesia.transaction(transaction) do
      {:atomic, [record]} ->
        {:ok, record_to_map(record)}

      {:atomic, []} ->
        {:error, :not_found}

      {:atomic, _multiple} ->
        # This shouldn't happen - IP should be unique
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease_storage, :multiple_found],
          %{count: 1},
          %{ip_address: ip_address}
        )

        {:error, :multiple_found}

      {:aborted, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease_storage, :read_by_ip_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Deletes a lease by MAC address.

  ## Parameters

  - `mac_address` - Client MAC address

  ## Returns

  - `:ok` - Successfully deleted or didn't exist
  """
  @spec delete(mac_address()) :: :ok
  def delete(mac_address) do
    transaction = fn ->
      :mnesia.delete(@table_name, mac_address, :write)
    end

    case :mnesia.transaction(transaction) do
      {:atomic, :ok} ->
        :ok

      {:aborted, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease_storage, :delete_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Lists all leases with optional filtering.

  ## Options

  - `:state` - Filter by state (e.g., :active, :expired)
  - `:pool_name` - Filter by pool name
  - `:active_only` - Only return non-expired leases (default: false)

  ## Returns

  - List of leases
  """
  @spec list(keyword()) :: [lease()]
  def list(opts \\ []) do
    state_filter = Keyword.get(opts, :state)
    pool_filter = Keyword.get(opts, :pool_name)
    active_only = Keyword.get(opts, :active_only, false)
    now = System.system_time(:second)

    transaction = fn ->
      pattern =
        cond do
          state_filter && pool_filter ->
            lease_record(state: state_filter, pool_name: pool_filter, _: :_)

          state_filter ->
            lease_record(state: state_filter, _: :_)

          pool_filter ->
            lease_record(pool_name: pool_filter, _: :_)

          true ->
            lease_record(_: :_)
        end

      :mnesia.match_object(@table_name, pattern, :read)
      |> Enum.map(&record_to_map/1)
      |> then(fn leases ->
        if active_only do
          Enum.filter(leases, fn lease ->
            lease.state == :active && lease.expires_at > now
          end)
        else
          leases
        end
      end)
    end

    case :mnesia.transaction(transaction) do
      {:atomic, leases} ->
        leases

      {:aborted, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease_storage, :list_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        []
    end
  end

  @doc """
  Gets all active (non-expired) leases.

  ## Returns

  - List of active leases
  """
  @spec list_active() :: [lease()]
  def list_active do
    list(active_only: true)
  end

  @doc """
  Gets all allocated IP addresses for active leases.

  ## Returns

  - MapSet of IP addresses
  """
  @spec get_allocated_ips() :: MapSet.t(ip_address())
  def get_allocated_ips do
    list_active()
    |> Enum.map(& &1.ip_address)
    |> MapSet.new()
  end

  @doc """
  Updates the state of a lease.

  ## Parameters

  - `mac_address` - Client MAC address
  - `new_state` - New lease state

  ## Returns

  - `{:ok, lease}` - Successfully updated
  - `{:error, reason}` - Failed to update
  """
  @spec update_state(mac_address(), lease_state()) :: {:ok, lease()} | {:error, term()}
  def update_state(mac_address, new_state) do
    transaction = fn ->
      case :mnesia.read(@table_name, mac_address) do
        [record] ->
          now = System.system_time(:second)

          updated_record =
            lease_record(record,
              state: new_state,
              updated_at: now
            )

          :mnesia.write(@table_name, updated_record, :write)
          record_to_map(updated_record)

        [] ->
          nil
      end
    end

    case :mnesia.transaction(transaction) do
      {:atomic, nil} ->
        {:error, :not_found}

      {:atomic, lease} ->
        {:ok, lease}

      {:aborted, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease_storage, :update_state_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Cleans up expired leases by updating their state to :expired.

  ## Returns

  - `{:ok, count}` - Number of leases expired
  """
  @spec cleanup_expired() :: {:ok, non_neg_integer()}
  def cleanup_expired do
    now = System.system_time(:second)

    transaction = fn ->
      # Find all active leases that have expired
      expired_records =
        :mnesia.match_object(@table_name, lease_record(state: :active, _: :_), :read)
        |> Enum.filter(fn record ->
          lease_record(expires_at: expires_at) = record
          expires_at <= now
        end)

      # Update each expired record
      Enum.each(expired_records, fn record ->
        updated_record =
          lease_record(record,
            state: :expired,
            updated_at: now
          )

        :mnesia.write(@table_name, updated_record, :write)
      end)

      # Return count of expired records
      length(expired_records)
    end

    case :mnesia.transaction(transaction) do
      {:atomic, count} ->
        if count > 0 do
          :telemetry.execute(
            [:yellow_dog, :dhcpv4, :lease_storage, :expired],
            %{count: count},
            %{}
          )
        end

        {:ok, count}

      {:aborted, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease_storage, :cleanup_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Gets storage statistics.

  ## Returns

  - Map with statistics
  """
  @spec stats() :: map()
  def stats do
    now = System.system_time(:second)
    all_leases = list()

    active_leases =
      Enum.filter(all_leases, fn lease ->
        lease.state == :active && lease.expires_at > now
      end)

    expired_leases = Enum.filter(all_leases, fn lease -> lease.expires_at <= now end)

    state_counts =
      Enum.reduce(all_leases, %{}, fn lease, acc ->
        Map.update(acc, lease.state, 1, &(&1 + 1))
      end)

    %{
      total_leases: length(all_leases),
      active_leases: length(active_leases),
      expired_leases: length(expired_leases),
      by_state: state_counts
    }
  end

  @doc """
  Clears all leases from storage.

  WARNING: This is destructive and should only be used for testing or maintenance.

  ## Returns

  - `:ok` - Successfully cleared
  """
  @spec clear_all() :: :ok | {:error, term()}
  def clear_all do
    # Note: :mnesia.clear_table/1 is already atomic, don't wrap in transaction
    # to avoid nested transaction issues
    case :mnesia.clear_table(@table_name) do
      {:atomic, :ok} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease_storage, :cleared],
          %{count: 1},
          %{}
        )

        :ok

      {:aborted, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease_storage, :clear_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  ## Private Functions

  defp ensure_schema_created(nodes) do
    case :mnesia.create_schema(nodes) do
      :ok ->
        :ok

      {:error, {_node, {:already_exists, _}}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_table_created(storage_type, nodes) do
    # Start Mnesia if not already started
    :mnesia.start()

    table_opts =
      [
        attributes: [
          :mac_address,
          :ip_address,
          :pool_name,
          :state,
          :lease_time,
          :expires_at,
          :hostname,
          :client_id,
          :created_at,
          :updated_at
        ],
        record_name: :lease_record,
        type: :set,
        index: [:ip_address, :state, :pool_name]
      ] ++ [{storage_type, nodes}]

    case :mnesia.create_table(@table_name, table_opts) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, @table_name}} ->
        # Table exists, ensure it has the right properties
        ensure_indices()
        :ok

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  defp ensure_indices do
    # Ensure secondary indices exist
    existing_indices = :mnesia.table_info(@table_name, :index)

    [:ip_address, :state, :pool_name]
    |> Enum.reject(&(&1 in existing_indices))
    |> Enum.each(fn attr ->
      case :mnesia.add_table_index(@table_name, attr) do
        {:atomic, :ok} ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv4, :lease_storage, :index_added],
            %{count: 1},
            %{attribute: attr}
          )

        {:aborted, {:already_exists, @table_name, _}} ->
          :ok

        {:aborted, reason} ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv4, :lease_storage, :index_failed],
            %{count: 1},
            %{attribute: attr, reason: inspect(reason)}
          )
      end
    end)
  end

  defp record_to_map(record) do
    lease_record(
      mac_address: mac,
      ip_address: ip,
      pool_name: pool,
      state: state,
      lease_time: lease_time,
      expires_at: expires_at,
      hostname: hostname,
      client_id: client_id,
      created_at: created_at,
      updated_at: updated_at
    ) = record

    %{
      mac_address: mac,
      ip_address: ip,
      pool_name: pool,
      state: state,
      lease_time: lease_time,
      expires_at: expires_at,
      hostname: hostname,
      client_id: client_id,
      created_at: created_at,
      updated_at: updated_at
    }
  end
end
