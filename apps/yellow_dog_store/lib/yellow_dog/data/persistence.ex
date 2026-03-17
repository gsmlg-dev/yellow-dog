defmodule YellowDog.Data.Persistence do
  @moduledoc """
  Behaviour for persistence strategies.

  A persistence strategy knows how to load records from and save records to
  durable storage (files, databases, etc.). The `Store.Ets` adapter uses
  persistence strategies to flush ETS data to disk on interval or terminate.

  Built-in strategies:

    * `YellowDog.Data.Persistence.Toml` — TOML file persistence (default)
  """

  @type opts :: map()

  @doc "Load records from persistent storage. Returns a list of `{key, record}` pairs."
  @callback load(opts()) :: {:ok, [{term(), term()}]} | {:error, term()}

  @doc "Save records to persistent storage."
  @callback save([{term(), term()}], opts()) :: :ok | {:error, term()}
end
