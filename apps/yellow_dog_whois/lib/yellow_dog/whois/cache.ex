defmodule YellowDog.Whois.Cache do
  @moduledoc """
  Cache behaviour for YellowDog.Whois lookups.

  Implement this behaviour to provide a custom cache backend:

      defmodule MyApp.WhoisCache do
        @behaviour YellowDog.Whois.Cache
        # implement get/1, put/4, delete/1, clear/0
      end

  Configure the backend via application config:

      config :yellow_dog_whois, cache: MyApp.WhoisCache

  To disable caching entirely:

      config :yellow_dog_whois, cache: nil

  Built-in backends:

  - `YellowDog.Whois.Cache.ETS` (default) — requires `start_link/0` in your supervision tree

  TTL configuration (milliseconds):

      config :yellow_dog_whois, cache_ttl: [
        domain: 86_400_000,   # 24 hours (default)
        ip: 3_600_000,        # 1 hour (default)
        asn: 3_600_000,       # 1 hour (default)
        rdap: 86_400_000      # 24 hours (default)
      ]
  """

  @type key :: String.t()
  @type value :: term()
  @type lookup_type :: :domain | :ip | :asn | :rdap | atom()

  @callback get(key()) :: {:ok, value()} | :miss
  @callback put(key(), value(), lookup_type(), ttl_ms :: non_neg_integer()) :: :ok
  @callback delete(key()) :: :ok
  @callback clear() :: :ok

  @default_ttl %{
    domain: 86_400_000,
    ip: 3_600_000,
    asn: 3_600_000,
    rdap: 86_400_000
  }

  @doc "Returns the configured cache backend module, or `nil` if caching is disabled."
  @spec impl() :: module() | nil
  def impl do
    case Application.get_env(:yellow_dog_whois, :cache, YellowDog.Whois.Cache.ETS) do
      false -> nil
      mod -> mod
    end
  end

  @doc "Returns the TTL in milliseconds for the given lookup type."
  @spec ttl(lookup_type()) :: non_neg_integer()
  def ttl(type) do
    config_ttl = Application.get_env(:yellow_dog_whois, :cache_ttl, %{})
    Map.get(config_ttl, type) || Map.get(@default_ttl, type, 3_600_000)
  end

  @doc "Retrieves a value. Returns `:miss` if caching is disabled or key absent."
  @spec get(key()) :: {:ok, value()} | :miss
  def get(key) do
    case impl() do
      nil -> :miss
      mod -> mod.get(key)
    end
  end

  @doc "Stores a value. No-op if caching is disabled."
  @spec put(key(), value(), lookup_type()) :: :ok
  def put(key, value, type) do
    case impl() do
      nil -> :ok
      mod -> mod.put(key, value, type, ttl(type))
    end
  end

  @doc "Deletes a single entry. No-op if caching is disabled."
  @spec delete(key()) :: :ok
  def delete(key) do
    case impl() do
      nil -> :ok
      mod -> mod.delete(key)
    end
  end

  @doc "Clears all entries. No-op if caching is disabled."
  @spec clear() :: :ok
  def clear do
    case impl() do
      nil -> :ok
      mod -> mod.clear()
    end
  end
end
