defmodule YellowDog.Store.Backend do
  @moduledoc """
  Behaviour defining the storage backend interface for the Store facade.

  Implementations:
    * `YellowDog.Store.Backend.Ets` — single-node ETS (no Raft overhead)
    * `YellowDog.Store.Backend.Cluster` — Concord-backed distributed store

  The active backend is resolved once by `YellowDog.Store.ModeDetector` and
  stored in `:persistent_term` for O(1) dispatch on every Store operation.
  """

  @type key :: String.t()
  @type value :: term()
  @type opts :: keyword()

  @doc "Write a key/value pair with optional TTL."
  @callback put(key(), value(), opts()) :: :ok

  @doc "Read a key. Returns `{:ok, value}` or `{:error, :not_found}`."
  @callback get(key(), opts()) :: {:ok, value()} | {:error, :not_found}

  @doc "Delete a key."
  @callback delete(key()) :: :ok

  @doc """
  Conditional write. Opts may include:
    * `:expected` — write only if current value equals expected (nil = key absent)
    * `:condition` — 1-arity function; return true/:update-tuple to proceed, false to reject
    * `:ttl` — TTL in seconds for the written value
  """
  @callback put_if(key(), value(), opts()) :: :ok | {:error, :condition_failed}

  @doc "Scan all keys with the given prefix. Opts may include `:limit`."
  @callback prefix_scan(key(), opts()) :: {:ok, [{key(), value()}]}

  @doc "Write multiple key/value pairs atomically."
  @callback put_many(list()) :: {:ok, map()}

  @doc "Execute a compare/operation transaction."
  @callback txn(map(), opts()) :: {:ok, map() | struct()} | {:error, term()}

  @doc "Describe the recovery guarantee provided by the backend."
  @callback recovery_durability() ::
              :caller_process_while_table_survives | :restart_durable

  @optional_callbacks txn: 2, recovery_durability: 0

  @doc "Returns the backend module for the current mode."
  @spec active() :: module()
  def active do
    :persistent_term.get({__MODULE__, :active}, YellowDog.Store.Backend.Ets)
  end

  @doc "Sets the active backend module (called by ModeDetector)."
  @spec set_active(module()) :: :ok
  def set_active(module) do
    :persistent_term.put({__MODULE__, :active}, module)
  end
end
