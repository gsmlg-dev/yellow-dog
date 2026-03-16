defmodule YellowDog.Data.Collection do
  @moduledoc """
  Describes a logical data collection and its storage configuration.

  Each domain data set (ACLs, zones, devices, leases, etc.) is represented
  by a `%Collection{}` that specifies:

    * Which adapter to use (`Store.Ets`, `Store.Mnesia`, etc.)
    * How to persist data to disk (optional TOML/JSON file)
    * Which field is the primary key
    * Secondary indexes for efficient queries

  ## Example

      %Collection{
        name: :dns_acls,
        key_field: :name,
        adapter: YellowDog.Data.Store.Ets,
        indexes: [],
        persistence: %{strategy: :toml, path: "data/dns/acls.toml", interval: 0},
        schema: nil
      }

  ## defcollection macro

  For convenience, domain modules can declare collections inline:

      use YellowDog.Data.Collection

      defcollection :dns_acls,
        key_field: :name,
        adapter: YellowDog.Data.Store.Ets,
        persistence: [strategy: :toml, path: "data/dns/acls.toml"]
  """

  @type persistence_config :: %{
          strategy: :toml | :json | nil,
          path: String.t() | nil,
          interval: non_neg_integer()
        }

  @type t :: %__MODULE__{
          name: atom(),
          key_field: atom(),
          adapter: module(),
          indexes: [atom()],
          persistence: persistence_config() | nil,
          schema: module() | nil
        }

  @enforce_keys [:name, :key_field, :adapter]
  defstruct [
    :name,
    :key_field,
    :adapter,
    :schema,
    indexes: [],
    persistence: nil
  ]

  @doc """
  Builds a `%Collection{}` from a keyword list, filling defaults.
  """
  @spec new(atom(), keyword()) :: t()
  def new(name, opts) when is_atom(name) do
    persistence = build_persistence(Keyword.get(opts, :persistence))

    %__MODULE__{
      name: name,
      key_field: Keyword.get(opts, :key_field, :id),
      adapter: Keyword.get(opts, :adapter, YellowDog.Data.Store.Ets),
      indexes: Keyword.get(opts, :indexes, []),
      persistence: persistence,
      schema: Keyword.get(opts, :schema)
    }
  end

  defp build_persistence(nil), do: nil

  defp build_persistence(opts) when is_list(opts) do
    %{
      strategy: Keyword.get(opts, :strategy, :toml),
      path: Keyword.get(opts, :path),
      interval: Keyword.get(opts, :interval, 0)
    }
  end

  defp build_persistence(%{} = map), do: map

  # ── defcollection macro ──────────────────────────────────────────

  defmacro __using__(_opts) do
    quote do
      import YellowDog.Data.Collection, only: [defcollection: 2]
    end
  end

  @doc """
  Declares a collection at compile time, generating a `collection/0` function
  that returns the `%Collection{}` struct.

  ## Example

      defcollection :dns_acls,
        key_field: :name,
        adapter: YellowDog.Data.Store.Ets

      # Generates: def collection, do: %Collection{name: :dns_acls, ...}
  """
  defmacro defcollection(name, opts) do
    quote bind_quoted: [name: name, opts: opts] do
      @__collection YellowDog.Data.Collection.new(name, opts)

      @doc "Returns the `%Collection{}` describing this module's data storage."
      @spec collection() :: YellowDog.Data.Collection.t()
      def collection, do: @__collection
    end
  end
end
