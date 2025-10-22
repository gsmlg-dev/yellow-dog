defmodule YellowDog.Mdns do
  @moduledoc """
  mDNS passive listener and service discovery.

  Provides a public API for interacting with the mDNS service,
  including querying cached messages and checking service status.
  """

  alias YellowDog.Mdns.{MessageCache, Supervisor}

  @doc """
  Starts the Mdns supervisor.

  Delegates to `YellowDog.Mdns.Supervisor.start_link/1`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(options), to: Supervisor

  @doc """
  Returns a child specification for the Mdns supervisor.

  Delegates to `YellowDog.Mdns.Supervisor.child_spec/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: Supervisor

  @doc """
  Queries cached mDNS messages by domain.

  ## Parameters
  - `domain` - Domain name to search for (e.g., "myservice.local")
  - `record_type` - Optional record type filter (e.g., :A, :AAAA, :PTR, :SRV, :TXT)

  ## Returns
  - List of matching cache entries

  ## Examples
      iex> YellowDog.Mdns.query("printer.local")
      [%{domain: "printer.local", record_type: :A, ...}]

      iex> YellowDog.Mdns.query("_http._tcp.local", :PTR)
      [%{domain: "_http._tcp.local", record_type: :PTR, ...}]
  """
  @spec query(String.t(), atom() | nil) :: [map()]
  defdelegate query(domain, record_type \\ nil), to: MessageCache

  @doc """
  Lists all cached mDNS messages.

  ## Returns
  - List of all cache entries
  """
  @spec list_all() :: [map()]
  defdelegate list_all(), to: MessageCache

  @doc """
  Gets cache statistics.

  ## Returns
  - Map with cache statistics including total, active, and expired entries

  ## Examples
      iex> YellowDog.Mdns.stats()
      %{
        total_entries: 150,
        active_entries: 120,
        expired_entries: 30
      }
  """
  @spec stats() :: map()
  defdelegate stats(), to: MessageCache

  @doc """
  Clears all entries from the cache.

  ## Returns
  - `:ok`
  """
  @spec clear_cache() :: :ok
  def clear_cache, do: MessageCache.clear()

  @doc """
  Gets the status of the mDNS service.

  ## Returns
  - Map with service status information

  ## Examples
      iex> YellowDog.Mdns.status()
      %{
        running: true,
        cache_stats: %{total_entries: 150, active_entries: 120, expired_entries: 30}
      }
  """
  @spec status() :: map()
  def status do
    case Process.whereis(Supervisor) do
      nil ->
        %{running: false, cache_stats: %{}}

      _pid ->
        %{
          running: true,
          cache_stats: stats()
        }
    end
  end
end
