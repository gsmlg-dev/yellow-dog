defmodule YellowDog.Data.Registry do
  @moduledoc """
  GenServer that tracks all active data collections.

  The Registry serves as the central catalog of all initialized collections
  in the system. Domain modules register their collections on startup and
  can query the registry to discover available data stores.

  ## Responsibilities

    * Track collection name → adapter state mappings
    * Provide `flush_all/0` for graceful shutdown (persist all collections)
    * Enable cross-collection queries in the future (resource relationships)

  ## Usage

      # Register a collection (typically done by domain module init)
      Registry.register(:dns_acls, adapter_state)

      # Look up a collection's adapter state
      {:ok, state} = Registry.lookup(:dns_acls)

      # Flush all collections to disk
      Registry.flush_all()
  """

  use GenServer

  require Logger

  alias YellowDog.Data.Store

  @type state :: %{collections: %{atom() => Store.state()}}

  # ── Client API ───────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Register a collection's adapter state."
  @spec register(atom(), Store.state(), GenServer.server()) :: :ok
  def register(name, adapter_state, server \\ __MODULE__) do
    GenServer.call(server, {:register, name, adapter_state})
  end

  @doc "Look up a collection's adapter state."
  @spec lookup(atom(), GenServer.server()) :: {:ok, Store.state()} | {:error, :not_found}
  def lookup(name, server \\ __MODULE__) do
    GenServer.call(server, {:lookup, name})
  end

  @doc "Unregister a collection."
  @spec unregister(atom(), GenServer.server()) :: :ok
  def unregister(name, server \\ __MODULE__) do
    GenServer.call(server, {:unregister, name})
  end

  @doc "List all registered collection names."
  @spec list_collections(GenServer.server()) :: [atom()]
  def list_collections(server \\ __MODULE__) do
    GenServer.call(server, :list_collections)
  end

  @doc "Flush all registered collections to persistent storage."
  @spec flush_all(GenServer.server()) :: :ok
  def flush_all(server \\ __MODULE__) do
    GenServer.call(server, :flush_all)
  end

  # ── GenServer callbacks ──────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{collections: %{}}}
  end

  @impl true
  def handle_call({:register, name, adapter_state}, _from, state) do
    collections = Map.put(state.collections, name, adapter_state)
    {:reply, :ok, %{state | collections: collections}}
  end

  def handle_call({:lookup, name}, _from, state) do
    case Map.fetch(state.collections, name) do
      {:ok, adapter_state} -> {:reply, {:ok, adapter_state}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:unregister, name}, _from, state) do
    collections = Map.delete(state.collections, name)
    {:reply, :ok, %{state | collections: collections}}
  end

  def handle_call(:list_collections, _from, state) do
    {:reply, Map.keys(state.collections), state}
  end

  def handle_call(:flush_all, _from, state) do
    Enum.each(state.collections, fn {_name, adapter_state} ->
      Store.flush(adapter_state)
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("#{__MODULE__} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.collections, fn {_name, adapter_state} ->
      Store.flush(adapter_state)
    end)
  end
end
