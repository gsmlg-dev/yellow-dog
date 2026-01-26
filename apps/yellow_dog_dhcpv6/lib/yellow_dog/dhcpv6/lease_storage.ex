defmodule YellowDog.Dhcpv6.LeaseStorage do
  @moduledoc """
  Persistent lease storage using Mnesia for DHCPv6.

  Provides durable, transactional storage for DHCPv6 leases with support for
  DUID-based client identification, multiple IA types, and comprehensive querying.

  ## Lease States

  - `:offered` - Address offered to client, awaiting REQUEST
  - `:active` - Lease active and in use by client
  - `:released` - Client released the lease voluntarily
  - `:expired` - Lease exceeded its lifetime
  - `:declined` - Client declined the offered address (conflict detected)

  ## IA Types

  - `:ia_na` - Identity Association for Non-temporary Addresses (standard addresses)
  - `:ia_ta` - Identity Association for Temporary Addresses (privacy extensions)
  - `:ia_pd` - Identity Association for Prefix Delegation (router prefix assignment)

  ## Storage Modes

  - `:disc_copies` - Persistent storage (default for production)
  - `:ram_copies` - Memory-only storage (for testing)
  """

  require Record

  alias YellowDog.Dhcpv6.AddressPool

  @type ipv6_address :: AddressPool.ipv6_address()
  @type duid :: AddressPool.duid()
  @type iaid :: non_neg_integer()
  @type lease_state :: :offered | :active | :released | :expired | :declined
  @type ia_type :: :ia_na | :ia_ta | :ia_pd

  @type lease :: %{
          duid: duid(),
          iaid: iaid(),
          ip_address: ipv6_address() | nil,
          delegated_prefix: {ipv6_address(), pos_integer()} | nil,
          pool_name: String.t(),
          ia_type: ia_type(),
          state: lease_state(),
          preferred_lifetime: pos_integer(),
          valid_lifetime: pos_integer(),
          expires_at: integer(),
          hostname: String.t() | nil,
          created_at: integer(),
          updated_at: integer()
        }

  # Define Mnesia record
  # Primary key is composite: {duid, iaid}
  Record.defrecord(:lease_record,
    lease_key: nil,
    duid: nil,
    iaid: nil,
    ip_address: nil,
    delegated_prefix: nil,
    pool_name: nil,
    ia_type: :ia_na,
    state: :offered,
    preferred_lifetime: 0,
    valid_lifetime: 0,
    expires_at: 0,
    hostname: nil,
    created_at: 0,
    updated_at: 0
  )

  @table_name :dhcpv6_leases

  ## Public API

  @doc """
  Initializes the Mnesia schema and creates the leases table.

  ## Options

  - `:storage_type` - `:disc_copies` (default) or `:ram_copies`
  - `:nodes` - List of nodes to create table on (default: [node()])
  - `:data_dir` - Directory for Mnesia data (default: uses YellowDog.Config)

  ## Returns

  - `:ok` - Successfully initialized
  - `{:error, reason}` - Failed to initialize
  """
  @spec init(keyword()) :: :ok | {:error, term()}
  def init(opts \\ []) do
    storage_type = Keyword.get(opts, :storage_type, :disc_copies)
    nodes = Keyword.get(opts, :nodes, [node()])

    # Configure Mnesia directory before creating schema (only for disc_copies)
    data_dir = get_data_dir(opts)

    if storage_type == :disc_copies do
      :ok = configure_mnesia_dir(data_dir)
    end

    # For ram_copies, skip schema creation (useful for tests)
    result =
      if storage_type == :ram_copies do
        ensure_table_created(storage_type, nodes)
      else
        with :ok <- ensure_schema_created(nodes),
             :ok <- ensure_table_created(storage_type, nodes) do
          :ok
        end
      end

    case result do
      :ok ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_storage, :initialized],
          %{count: 1},
          %{storage_type: storage_type, nodes: nodes, data_dir: data_dir}
        )

        :ok

      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_storage, :init_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        error
    end
  end

  # Gets the data directory from options or YellowDog.Config
  defp get_data_dir(opts) do
    case Keyword.get(opts, :data_dir) do
      nil ->
        # Try to get from YellowDog.Config if available
        try do
          YellowDog.Config.get_service_data_dir(:dhcpv6)
        rescue
          _ -> "data/dhcpv6"
        end

      dir ->
        dir
    end
  end

  # Configures the Mnesia directory
  defp configure_mnesia_dir(data_dir) do
    # Ensure the directory exists
    File.mkdir_p!(data_dir)

    # Set Mnesia directory (must be done before :mnesia.start())
    mnesia_dir = String.to_charlist(data_dir)
    Application.put_env(:mnesia, :dir, mnesia_dir)
    :ok
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
    lease_key = make_lease_key(lease.duid, lease.iaid)

    record =
      lease_record(
        lease_key: lease_key,
        duid: lease.duid,
        iaid: lease.iaid,
        ip_address: lease[:ip_address],
        delegated_prefix: lease[:delegated_prefix],
        pool_name: lease.pool_name,
        ia_type: lease[:ia_type] || :ia_na,
        state: lease.state,
        preferred_lifetime: lease.preferred_lifetime,
        valid_lifetime: lease.valid_lifetime,
        expires_at: lease.expires_at,
        hostname: lease[:hostname],
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
          [:yellow_dog, :dhcpv6, :lease_storage, :store_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Retrieves a lease by DUID and IAID.

  ## Parameters

  - `duid` - Client DUID (DHCP Unique Identifier)
  - `iaid` - Identity Association Identifier

  ## Returns

  - `{:ok, lease}` - Lease found
  - `{:error, :not_found}` - No lease exists
  """
  @spec get(duid(), iaid()) :: {:ok, lease()} | {:error, :not_found}
  def get(duid, iaid) do
    lease_key = make_lease_key(duid, iaid)

    transaction = fn ->
      case :mnesia.read(@table_name, lease_key) do
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
          [:yellow_dog, :dhcpv6, :lease_storage, :read_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Retrieves a lease by IPv6 address.

  ## Parameters

  - `ip_address` - IPv6 address tuple

  ## Returns

  - `{:ok, lease}` - Lease found
  - `{:error, :not_found}` - No lease exists
  """
  @spec get_by_ip(ipv6_address()) :: {:ok, lease()} | {:error, :not_found}
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
          [:yellow_dog, :dhcpv6, :lease_storage, :multiple_found],
          %{count: 1},
          %{ip_address: ip_address}
        )

        {:error, :multiple_found}

      {:aborted, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_storage, :read_by_ip_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Retrieves all leases for a specific DUID (all IAIDs).

  ## Parameters

  - `duid` - Client DUID

  ## Returns

  - List of leases for this DUID
  """
  @spec get_by_duid(duid()) :: [lease()]
  def get_by_duid(duid) do
    transaction = fn ->
      :mnesia.match_object(@table_name, lease_record(duid: duid, _: :_), :read)
      |> Enum.map(&record_to_map/1)
    end

    case :mnesia.transaction(transaction) do
      {:atomic, leases} ->
        leases

      {:aborted, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_storage, :read_by_duid_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        []
    end
  end

  @doc """
  Deletes a lease by DUID and IAID.

  ## Parameters

  - `duid` - Client DUID
  - `iaid` - Identity Association Identifier

  ## Returns

  - `:ok` - Successfully deleted or didn't exist
  """
  @spec delete(duid(), iaid()) :: :ok
  def delete(duid, iaid) do
    lease_key = make_lease_key(duid, iaid)

    transaction = fn ->
      :mnesia.delete(@table_name, lease_key, :write)
    end

    case :mnesia.transaction(transaction) do
      {:atomic, :ok} ->
        :ok

      {:aborted, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_storage, :delete_failed],
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
  - `:ia_type` - Filter by IA type (:ia_na, :ia_ta, :ia_pd)
  - `:active_only` - Only return non-expired leases (default: false)

  ## Returns

  - List of leases
  """
  @spec list(keyword()) :: [lease()]
  def list(opts \\ []) do
    state_filter = Keyword.get(opts, :state)
    pool_filter = Keyword.get(opts, :pool_name)
    ia_type_filter = Keyword.get(opts, :ia_type)
    active_only = Keyword.get(opts, :active_only, false)
    now = System.system_time(:second)

    transaction = fn ->
      pattern =
        cond do
          state_filter && pool_filter && ia_type_filter ->
            lease_record(
              state: state_filter,
              pool_name: pool_filter,
              ia_type: ia_type_filter,
              _: :_
            )

          state_filter && pool_filter ->
            lease_record(state: state_filter, pool_name: pool_filter, _: :_)

          state_filter && ia_type_filter ->
            lease_record(state: state_filter, ia_type: ia_type_filter, _: :_)

          pool_filter && ia_type_filter ->
            lease_record(pool_name: pool_filter, ia_type: ia_type_filter, _: :_)

          state_filter ->
            lease_record(state: state_filter, _: :_)

          pool_filter ->
            lease_record(pool_name: pool_filter, _: :_)

          ia_type_filter ->
            lease_record(ia_type: ia_type_filter, _: :_)

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
          [:yellow_dog, :dhcpv6, :lease_storage, :list_failed],
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
  Gets all allocated IPv6 addresses for active leases.

  ## Returns

  - MapSet of IPv6 addresses
  """
  @spec get_allocated_ips() :: MapSet.t(ipv6_address())
  def get_allocated_ips do
    list_active()
    |> Enum.filter(fn lease -> lease.ip_address != nil end)
    |> Enum.map(& &1.ip_address)
    |> MapSet.new()
  end

  @doc """
  Gets all allocated delegated prefixes for active leases.

  ## Returns

  - MapSet of {prefix, prefix_length} tuples
  """
  @spec get_allocated_prefixes() :: MapSet.t({ipv6_address(), pos_integer()})
  def get_allocated_prefixes do
    list(ia_type: :ia_pd, active_only: true)
    |> Enum.filter(fn lease -> lease.delegated_prefix != nil end)
    |> Enum.map(& &1.delegated_prefix)
    |> MapSet.new()
  end

  @doc """
  Updates the state of a lease.

  ## Parameters

  - `duid` - Client DUID
  - `iaid` - Identity Association Identifier
  - `new_state` - New lease state

  ## Returns

  - `{:ok, lease}` - Successfully updated
  - `{:error, reason}` - Failed to update
  """
  @spec update_state(duid(), iaid(), lease_state()) :: {:ok, lease()} | {:error, term()}
  def update_state(duid, iaid, new_state) do
    lease_key = make_lease_key(duid, iaid)

    transaction = fn ->
      case :mnesia.read(@table_name, lease_key) do
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
          [:yellow_dog, :dhcpv6, :lease_storage, :update_state_failed],
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
      expired_leases =
        :mnesia.match_object(@table_name, lease_record(state: :active, _: :_), :read)
        |> Enum.filter(fn record ->
          lease_record(expires_at: expires_at) = record
          expires_at <= now
        end)

      Enum.each(expired_leases, fn record ->
        updated_record =
          lease_record(record,
            state: :expired,
            updated_at: now
          )

        :mnesia.write(@table_name, updated_record, :write)
      end)

      length(expired_leases)
    end

    case :mnesia.transaction(transaction) do
      {:atomic, count} ->
        if count > 0 do
          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :lease_storage, :expired],
            %{count: count},
            %{}
          )
        end

        {:ok, count}

      {:aborted, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_storage, :cleanup_failed],
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

    ia_type_counts =
      Enum.reduce(all_leases, %{}, fn lease, acc ->
        Map.update(acc, lease.ia_type, 1, &(&1 + 1))
      end)

    %{
      total_leases: length(all_leases),
      active_leases: length(active_leases),
      expired_leases: length(expired_leases),
      by_state: state_counts,
      by_ia_type: ia_type_counts
    }
  end

  @doc """
  Clears all leases from storage.

  WARNING: This is destructive and should only be used for testing or maintenance.

  ## Returns

  - `:ok` - Successfully cleared
  """
  @spec clear_all() :: :ok
  def clear_all do
    # Use dirty operations to avoid nested transaction issues in tests
    :mnesia.clear_table(@table_name)

    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :lease_storage, :cleared],
      %{count: 1},
      %{}
    )

    :ok
  end

  ## Private Functions

  defp make_lease_key(duid, iaid) do
    # Create a composite key from DUID and IAID
    # Using erlang term_to_binary for consistent key generation
    :erlang.phash2({duid, iaid}, 4_294_967_296)
  end

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
          :lease_key,
          :duid,
          :iaid,
          :ip_address,
          :delegated_prefix,
          :pool_name,
          :ia_type,
          :state,
          :preferred_lifetime,
          :valid_lifetime,
          :expires_at,
          :hostname,
          :created_at,
          :updated_at
        ],
        record_name: :lease_record,
        type: :set,
        index: [:ip_address, :duid, :state, :pool_name, :ia_type]
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

    [:ip_address, :duid, :state, :pool_name, :ia_type]
    |> Enum.reject(&(&1 in existing_indices))
    |> Enum.each(fn attr ->
      case :mnesia.add_table_index(@table_name, attr) do
        {:atomic, :ok} ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :lease_storage, :index_added],
            %{count: 1},
            %{attribute: attr}
          )

        {:aborted, {:already_exists, @table_name, _}} ->
          :ok

        {:aborted, reason} ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :lease_storage, :index_failed],
            %{count: 1},
            %{attribute: attr, reason: inspect(reason)}
          )
      end
    end)
  end

  defp record_to_map(record) do
    lease_record(
      lease_key: _key,
      duid: duid,
      iaid: iaid,
      ip_address: ip,
      delegated_prefix: prefix,
      pool_name: pool,
      ia_type: ia_type,
      state: state,
      preferred_lifetime: preferred,
      valid_lifetime: valid,
      expires_at: expires_at,
      hostname: hostname,
      created_at: created_at,
      updated_at: updated_at
    ) = record

    %{
      duid: duid,
      iaid: iaid,
      ip_address: ip,
      delegated_prefix: prefix,
      pool_name: pool,
      ia_type: ia_type,
      state: state,
      preferred_lifetime: preferred,
      valid_lifetime: valid,
      expires_at: expires_at,
      hostname: hostname,
      created_at: created_at,
      updated_at: updated_at
    }
  end
end
