defmodule YellowDog.Data.Store do
  @moduledoc """
  Behaviour defining the unified storage API for all Yellow Dog data.

  Adapters implement these callbacks to provide pluggable backends:

    * `YellowDog.Data.Store.Ets` — default in-memory adapter (ETS tables + optional file persistence)
    * `YellowDog.Data.Store.Mnesia` — for transactional DHCP leases (stub, future)
    * `YellowDog.Data.Store.Postgres` — for large datasets (future)
    * `YellowDog.Data.Store.Concord` — distributed KV via Raft (future)

  ## Usage

  Domain modules declare a `%Collection{}` with an adapter, then call
  `Store` functions which dispatch to the adapter:

      collection = %Collection{name: :dns_acls, adapter: Store.Ets, ...}
      {:ok, state} = Store.init(collection, [])
      {:ok, state} = Store.put(state, "my_acl", %{name: "my_acl", entries: []})
      {:ok, acl} = Store.get(state, "my_acl")

  Each function takes the adapter state as the first argument and dispatches
  to the adapter module specified in the collection.
  """

  alias YellowDog.Data.Collection

  @type state :: term()
  @type key :: term()
  @type record :: term()
  @type filter_fn :: (record() -> boolean())
  @type update_fn :: (record() -> record())
  @type pattern :: map()
  @type event :: :inserted | :updated | :deleted | :cleared
  @type format :: :toml | :json | :csv

  # ── Lifecycle ────────────────────────────────────────────────────

  @doc "Initialize storage for a collection. Returns adapter state."
  @callback init(collection :: Collection.t(), opts :: keyword()) ::
              {:ok, state()} | {:error, term()}

  @doc "Persist any buffered data to durable storage."
  @callback flush(state()) :: :ok | {:error, term()}

  # ── CRUD ─────────────────────────────────────────────────────────

  @doc "Fetch a single record by key."
  @callback get(state(), key()) :: {:ok, record()} | {:error, :not_found}

  @doc "Insert or replace a record."
  @callback put(state(), key(), record()) :: {:ok, state()} | {:error, term()}

  @doc "Delete a record by key."
  @callback delete(state(), key()) :: {:ok, state()} | {:error, term()}

  @doc "Check if a record exists."
  @callback exists?(state(), key()) :: boolean()

  # ── Query ────────────────────────────────────────────────────────

  @doc "List all records."
  @callback list(state()) :: {:ok, [record()]}

  @doc "List records matching a filter function."
  @callback list(state(), filter_fn()) :: {:ok, [record()]}

  @doc "Count all records."
  @callback count(state()) :: {:ok, non_neg_integer()}

  @doc "Find records matching a map pattern (subset match)."
  @callback match(state(), pattern()) :: {:ok, [record()]}

  # ── Mutation ─────────────────────────────────────────────────────

  @doc "Read-modify-write a single record atomically."
  @callback update(state(), key(), update_fn()) ::
              {:ok, record(), state()} | {:error, term()}

  @doc "Remove all records."
  @callback clear(state()) :: {:ok, state()}

  # ── Advanced ─────────────────────────────────────────────────────

  @doc "Execute a function within a transaction (adapter-dependent)."
  @callback transaction(state(), (-> term())) :: {:ok, term()} | {:error, term()}

  @doc "Subscribe to change events for this collection."
  @callback subscribe(state(), event()) :: :ok | {:error, term()}

  @doc "Export all records in the given format."
  @callback export(state(), format()) :: {:ok, binary()} | {:error, term()}

  # ── Optional callbacks with defaults ─────────────────────────────

  @optional_callbacks [transaction: 2, subscribe: 2, export: 2, match: 2]

  # ── Dispatch helpers ─────────────────────────────────────────────

  @doc "Initialize storage for a collection, dispatching to its adapter."
  @spec init(Collection.t(), keyword()) :: {:ok, state()} | {:error, term()}
  def init(%Collection{adapter: adapter} = collection, opts) do
    adapter.init(collection, opts)
  end

  @doc "Fetch a single record by key."
  @spec get(state(), key()) :: {:ok, record()} | {:error, :not_found}
  def get(%{__adapter__: adapter} = state, key) do
    adapter.get(state, key)
  end

  @doc "Insert or replace a record."
  @spec put(state(), key(), record()) :: {:ok, state()} | {:error, term()}
  def put(%{__adapter__: adapter} = state, key, record) do
    adapter.put(state, key, record)
  end

  @doc "Delete a record by key."
  @spec delete(state(), key()) :: {:ok, state()} | {:error, term()}
  def delete(%{__adapter__: adapter} = state, key) do
    adapter.delete(state, key)
  end

  @doc "Check if a record exists."
  @spec exists?(state(), key()) :: boolean()
  def exists?(%{__adapter__: adapter} = state, key) do
    adapter.exists?(state, key)
  end

  @doc "List all records."
  @spec list(state()) :: {:ok, [record()]}
  def list(%{__adapter__: adapter} = state) do
    adapter.list(state)
  end

  @doc "List records matching a filter."
  @spec list(state(), filter_fn()) :: {:ok, [record()]}
  def list(%{__adapter__: adapter} = state, filter_fn) do
    adapter.list(state, filter_fn)
  end

  @doc "Count all records."
  @spec count(state()) :: {:ok, non_neg_integer()}
  def count(%{__adapter__: adapter} = state) do
    adapter.count(state)
  end

  @doc "Find records matching a map pattern."
  @spec match(state(), pattern()) :: {:ok, [record()]}
  def match(%{__adapter__: adapter} = state, pattern) do
    adapter.match(state, pattern)
  end

  @doc "Read-modify-write a single record."
  @spec update(state(), key(), update_fn()) :: {:ok, record(), state()} | {:error, term()}
  def update(%{__adapter__: adapter} = state, key, update_fn) do
    adapter.update(state, key, update_fn)
  end

  @doc "Remove all records."
  @spec clear(state()) :: {:ok, state()}
  def clear(%{__adapter__: adapter} = state) do
    adapter.clear(state)
  end

  @doc "Persist buffered data."
  @spec flush(state()) :: :ok | {:error, term()}
  def flush(%{__adapter__: adapter} = state) do
    adapter.flush(state)
  end

  @doc "Execute within a transaction."
  @spec transaction(state(), (-> term())) :: {:ok, term()} | {:error, term()}
  def transaction(%{__adapter__: adapter} = state, fun) do
    if function_exported?(adapter, :transaction, 2) do
      adapter.transaction(state, fun)
    else
      # Default: just execute the function (no transactional guarantees)
      {:ok, fun.()}
    end
  end

  @doc "Subscribe to change events."
  @spec subscribe(state(), event()) :: :ok | {:error, term()}
  def subscribe(%{__adapter__: adapter} = state, event) do
    if function_exported?(adapter, :subscribe, 2) do
      adapter.subscribe(state, event)
    else
      :ok
    end
  end

  @doc "Export records in the given format."
  @spec export(state(), format()) :: {:ok, binary()} | {:error, term()}
  def export(%{__adapter__: adapter} = state, format) do
    if function_exported?(adapter, :export, 2) do
      adapter.export(state, format)
    else
      {:error, :not_implemented}
    end
  end
end
