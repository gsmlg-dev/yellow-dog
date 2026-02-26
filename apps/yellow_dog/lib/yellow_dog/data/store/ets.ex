defmodule YellowDog.Data.Store.Ets do
  @moduledoc """
  Default in-memory storage adapter using ETS tables.

  Creates a named ETS table per collection with `:set` type and
  `read_concurrency: true` for fast concurrent reads. Mutations go through
  the adapter functions which also handle PubSub broadcasts and persistence.

  ## State

  The adapter state is a map containing:

    * `:__adapter__` — `YellowDog.Data.Store.Ets` (for dispatch)
    * `:table` — ETS table reference
    * `:collection` — the `%Collection{}` struct
    * `:persistence_opts` — resolved persistence config (or nil)
    * `:broadcast_fn` — `fun(event, key, record)` for change notifications (or nil)

  ## Persistence

  When a collection has `persistence: %{strategy: :toml, path: "..."}`,
  the adapter loads data from the file on `init/2` and writes on `flush/1`.
  The caller (typically a GenServer or the `Data.Registry`) is responsible
  for calling `flush/1` on interval or terminate.

  ## Direct ETS reads

  For performance, callers may read the named ETS table directly using
  `get/2` and `list/1` without going through a GenServer. All mutation
  operations should go through the adapter to maintain consistency.
  """

  @behaviour YellowDog.Data.Store

  alias YellowDog.Data.{Collection, Persistence}

  @type state :: %{
          __adapter__: __MODULE__,
          table: :ets.table(),
          collection: Collection.t(),
          persistence_opts: map() | nil,
          broadcast_fn: (atom(), term(), term() -> :ok) | nil
        }

  # ── Lifecycle ────────────────────────────────────────────────────

  @impl true
  @spec init(Collection.t(), keyword()) :: {:ok, state()} | {:error, term()}
  def init(%Collection{} = collection, opts \\ []) do
    table_name = Keyword.get(opts, :table_name, collection.name)

    ets_opts =
      Keyword.get(opts, :ets_opts, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])

    table = :ets.new(table_name, ets_opts)

    persistence_opts = build_persistence_opts(collection, opts)

    broadcast_fn = Keyword.get(opts, :broadcast_fn)

    state = %{
      __adapter__: __MODULE__,
      table: table,
      collection: collection,
      persistence_opts: persistence_opts,
      broadcast_fn: broadcast_fn
    }

    # Load from persistent storage if configured
    state =
      case load_persisted(state) do
        {:ok, pairs} ->
          Enum.each(pairs, fn {key, record} -> :ets.insert(table, {key, record}) end)
          state

        {:error, _reason} ->
          state
      end

    {:ok, state}
  end

  # ── CRUD ─────────────────────────────────────────────────────────

  @impl true
  @spec get(state(), term()) :: {:ok, term()} | {:error, :not_found}
  def get(%{table: table}, key) do
    case :ets.lookup(table, key) do
      [{^key, record}] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  @spec put(state(), term(), term()) :: {:ok, state()} | {:error, term()}
  def put(%{table: table} = state, key, record) do
    existed = :ets.member(table, key)
    :ets.insert(table, {key, record})
    event = if existed, do: :updated, else: :inserted
    broadcast(state, event, key, record)
    {:ok, state}
  end

  @impl true
  @spec delete(state(), term()) :: {:ok, state()} | {:error, term()}
  def delete(%{table: table} = state, key) do
    case :ets.lookup(table, key) do
      [{^key, record}] ->
        :ets.delete(table, key)
        broadcast(state, :deleted, key, record)
        {:ok, state}

      [] ->
        {:ok, state}
    end
  end

  @impl true
  @spec exists?(state(), term()) :: boolean()
  def exists?(%{table: table}, key) do
    :ets.member(table, key)
  end

  # ── Query ────────────────────────────────────────────────────────

  @impl true
  @spec list(state()) :: {:ok, [term()]}
  def list(%{table: table}) do
    records = :ets.foldl(fn {_key, record}, acc -> [record | acc] end, [], table)
    {:ok, records}
  end

  @impl true
  @spec list(state(), (term() -> boolean())) :: {:ok, [term()]}
  def list(%{table: table}, filter_fn) do
    records =
      :ets.foldl(
        fn {_key, record}, acc ->
          if filter_fn.(record), do: [record | acc], else: acc
        end,
        [],
        table
      )

    {:ok, records}
  end

  @impl true
  @spec count(state()) :: {:ok, non_neg_integer()}
  def count(%{table: table}) do
    {:ok, :ets.info(table, :size)}
  end

  @impl true
  @spec match(state(), map()) :: {:ok, [term()]}
  def match(%{table: table}, pattern) when is_map(pattern) do
    records =
      :ets.foldl(
        fn {_key, record}, acc ->
          if map_matches?(record, pattern), do: [record | acc], else: acc
        end,
        [],
        table
      )

    {:ok, records}
  end

  # ── Mutation ─────────────────────────────────────────────────────

  @impl true
  @spec update(state(), term(), (term() -> term())) ::
          {:ok, term(), state()} | {:error, term()}
  def update(%{table: table} = state, key, update_fn) do
    case :ets.lookup(table, key) do
      [{^key, record}] ->
        updated = update_fn.(record)
        :ets.insert(table, {key, updated})
        broadcast(state, :updated, key, updated)
        {:ok, updated, state}

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  @spec clear(state()) :: {:ok, state()}
  def clear(%{table: table} = state) do
    :ets.delete_all_objects(table)
    broadcast(state, :cleared, nil, nil)
    {:ok, state}
  end

  # ── Persistence ──────────────────────────────────────────────────

  @impl true
  @spec flush(state()) :: :ok | {:error, term()}
  def flush(%{persistence_opts: nil}), do: :ok

  def flush(%{table: table, persistence_opts: opts}) do
    pairs = :ets.tab2list(table)
    strategy = Map.fetch!(opts, :strategy_module)
    strategy.save(pairs, opts)
  end

  # ── Advanced ─────────────────────────────────────────────────────

  @impl true
  def transaction(_state, fun) do
    # ETS doesn't support real transactions — just execute
    {:ok, fun.()}
  rescue
    e -> {:error, e}
  end

  @impl true
  def subscribe(_state, _event), do: {:error, :not_implemented}

  @impl true
  def export(%{table: table}, :json) do
    records = Enum.map(:ets.tab2list(table), fn {_k, v} -> v end)

    case Jason.encode(records) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:json_encoding_failed, reason}}
    end
  end

  def export(_state, format), do: {:error, {:unsupported_format, format}}

  # ── Internal helpers ─────────────────────────────────────────────

  defp build_persistence_opts(%Collection{persistence: nil}, _opts), do: nil

  defp build_persistence_opts(%Collection{persistence: config, key_field: key_field}, opts) do
    strategy = Map.get(config, :strategy, :toml)

    strategy_module =
      case strategy do
        :toml -> Persistence.Toml
        mod when is_atom(mod) -> mod
      end

    %{
      strategy_module: strategy_module,
      path: Map.fetch!(config, :path),
      key_field: key_field,
      section: Keyword.get(opts, :section, "records"),
      serialize: Keyword.get(opts, :serialize),
      deserialize: Keyword.get(opts, :deserialize),
      backup: Keyword.get(opts, :backup, false)
    }
  end

  defp load_persisted(%{persistence_opts: nil}), do: {:ok, []}

  defp load_persisted(%{persistence_opts: opts}) do
    strategy = Map.fetch!(opts, :strategy_module)
    strategy.load(opts)
  end

  defp broadcast(%{broadcast_fn: nil}, _event, _key, _record), do: :ok

  defp broadcast(%{broadcast_fn: fun}, event, key, record) when is_function(fun, 3) do
    fun.(event, key, record)
  rescue
    _ -> :ok
  end

  defp map_matches?(record, pattern) when is_map(record) and is_map(pattern) do
    Enum.all?(pattern, fn {key, value} ->
      Map.get(record, key) == value || Map.get(record, to_string(key)) == value
    end)
  end

  defp map_matches?(_record, _pattern), do: false
end
