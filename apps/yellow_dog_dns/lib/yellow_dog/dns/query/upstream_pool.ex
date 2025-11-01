defmodule YellowDog.Dns.Query.UpstreamPool do
  @moduledoc """
  Manages a pool of upstream DNS servers for query forwarding.

  Provides health checking, failover, and load balancing for upstream
  DNS servers used in forward zones.

  ## Features
  - Health status tracking for each server
  - Automatic failover to healthy servers
  - Round-robin and random load balancing
  - Configurable health check intervals
  - Server marking (up/down based on query results)

  ## Example

      pool = UpstreamPool.new([
        {"8.8.8.8", 53},
        {"1.1.1.1", 53},
        {"9.9.9.9", 53}
      ])

      # Get next healthy server
      {:ok, {host, port}} = UpstreamPool.get_server(pool)

      # Mark server as down on failure
      pool = UpstreamPool.mark_down(pool, {"8.8.8.8", 53})

      # Mark server as up on success
      pool = UpstreamPool.mark_up(pool, {"8.8.8.8", 53})
  """

  @type server :: {String.t() | :inet.ip_address(), non_neg_integer()}
  @type server_status :: :up | :down
  @type selection_strategy :: :round_robin | :random | :first_available

  defmodule ServerState do
    @moduledoc false

    defstruct [
      :server,
      :status,
      :failures,
      :last_check,
      :last_failure
    ]

    @type t :: %__MODULE__{
            server: YellowDog.Dns.Query.UpstreamPool.server(),
            status: YellowDog.Dns.Query.UpstreamPool.server_status(),
            failures: non_neg_integer(),
            last_check: integer() | nil,
            last_failure: integer() | nil
          }
  end

  defstruct [
    :servers,
    :strategy,
    :current_index,
    :max_failures,
    :failure_timeout
  ]

  @type t :: %__MODULE__{
          servers: [ServerState.t()],
          strategy: selection_strategy(),
          current_index: non_neg_integer(),
          max_failures: non_neg_integer(),
          failure_timeout: non_neg_integer()
        }

  @default_max_failures 3
  @default_failure_timeout 30_000  # 30 seconds

  @doc """
  Creates a new upstream server pool.

  ## Parameters
  - `servers` - List of {host, port} tuples for upstream servers
  - `opts` - Optional configuration

  ## Options
  - `:strategy` - Load balancing strategy (:round_robin, :random, :first_available). Default: :round_robin
  - `:max_failures` - Maximum consecutive failures before marking server down. Default: 3
  - `:failure_timeout` - Milliseconds before retrying a down server. Default: 30000

  ## Examples

      iex> UpstreamPool.new([{"8.8.8.8", 53}, {"1.1.1.1", 53}])
      %UpstreamPool{servers: [...], strategy: :round_robin}

      iex> UpstreamPool.new([{"8.8.8.8", 53}], strategy: :random, max_failures: 5)
      %UpstreamPool{strategy: :random, max_failures: 5}
  """
  def new(servers, opts \\ []) when is_list(servers) do
    server_states =
      Enum.map(servers, fn server ->
        %ServerState{
          server: server,
          status: :up,
          failures: 0,
          last_check: nil,
          last_failure: nil
        }
      end)

    %__MODULE__{
      servers: server_states,
      strategy: Keyword.get(opts, :strategy, :round_robin),
      current_index: 0,
      max_failures: Keyword.get(opts, :max_failures, @default_max_failures),
      failure_timeout: Keyword.get(opts, :failure_timeout, @default_failure_timeout)
    }
  end

  @doc """
  Gets the next healthy upstream server from the pool.

  Returns `{:ok, {host, port}}` if a healthy server is available,
  or `{:error, :no_servers_available}` if all servers are down.

  The selection algorithm depends on the configured strategy:
  - `:round_robin` - Cycles through servers in order
  - `:random` - Selects a random healthy server
  - `:first_available` - Always uses the first healthy server

  ## Examples

      iex> {:ok, {host, port}} = UpstreamPool.get_server(pool)
      {:ok, {"8.8.8.8", 53}}

      iex> UpstreamPool.get_server(pool_with_all_down)
      {:error, :no_servers_available}
  """
  def get_server(%__MODULE__{servers: servers, strategy: strategy} = pool) do
    # Filter for healthy servers (check timeouts for down servers)
    now = System.system_time(:millisecond)
    healthy_servers = get_healthy_servers(servers, now, pool.failure_timeout)

    case healthy_servers do
      [] ->
        {:error, :no_servers_available}

      [server_state | _] = available ->
        selected = select_server(available, strategy, pool.current_index)
        new_index = update_index(pool.servers, selected, pool.current_index, strategy)

        {:ok, selected.server, %{pool | current_index: new_index}}
    end
  end

  @doc """
  Marks an upstream server as down due to query failure.

  Increments the failure counter and marks the server as down if it
  exceeds the maximum failures threshold.

  ## Examples

      iex> UpstreamPool.mark_down(pool, {"8.8.8.8", 53})
      %UpstreamPool{servers: [...]}
  """
  def mark_down(%__MODULE__{servers: servers, max_failures: max_failures} = pool, server) do
    now = System.system_time(:millisecond)

    updated_servers =
      Enum.map(servers, fn state ->
        if state.server == server do
          new_failures = state.failures + 1
          new_status = if new_failures >= max_failures, do: :down, else: state.status

          %{state |
            failures: new_failures,
            status: new_status,
            last_failure: now,
            last_check: now
          }
        else
          state
        end
      end)

    %{pool | servers: updated_servers}
  end

  @doc """
  Marks an upstream server as up after successful query.

  Resets the failure counter and ensures the server is marked as up.

  ## Examples

      iex> UpstreamPool.mark_up(pool, {"8.8.8.8", 53})
      %UpstreamPool{servers: [...]}
  """
  def mark_up(%__MODULE__{servers: servers} = pool, server) do
    now = System.system_time(:millisecond)

    updated_servers =
      Enum.map(servers, fn state ->
        if state.server == server do
          %{state |
            failures: 0,
            status: :up,
            last_check: now
          }
        else
          state
        end
      end)

    %{pool | servers: updated_servers}
  end

  @doc """
  Gets the current health status of all servers in the pool.

  ## Examples

      iex> UpstreamPool.get_status(pool)
      [
        %{server: {"8.8.8.8", 53}, status: :up, failures: 0},
        %{server: {"1.1.1.1", 53}, status: :down, failures: 3}
      ]
  """
  def get_status(%__MODULE__{servers: servers}) do
    Enum.map(servers, fn state ->
      %{
        server: state.server,
        status: state.status,
        failures: state.failures,
        last_check: state.last_check,
        last_failure: state.last_failure
      }
    end)
  end

  @doc """
  Adds a server to the pool.

  ## Examples

      iex> UpstreamPool.add_server(pool, {"9.9.9.9", 53})
      %UpstreamPool{servers: [...]}
  """
  def add_server(%__MODULE__{servers: servers} = pool, server) do
    # Check if server already exists
    exists? = Enum.any?(servers, fn state -> state.server == server end)

    if exists? do
      pool
    else
      new_state = %ServerState{
        server: server,
        status: :up,
        failures: 0,
        last_check: nil,
        last_failure: nil
      }

      %{pool | servers: servers ++ [new_state]}
    end
  end

  @doc """
  Removes a server from the pool.

  ## Examples

      iex> UpstreamPool.remove_server(pool, {"8.8.8.8", 53})
      %UpstreamPool{servers: [...]}
  """
  def remove_server(%__MODULE__{servers: servers} = pool, server) do
    updated_servers = Enum.reject(servers, fn state -> state.server == server end)
    %{pool | servers: updated_servers}
  end

  # Private helpers

  defp get_healthy_servers(servers, now, failure_timeout) do
    Enum.filter(servers, fn state ->
      case state.status do
        :up ->
          true

        :down ->
          # Check if enough time has passed to retry
          if state.last_failure do
            now - state.last_failure >= failure_timeout
          else
            false
          end
      end
    end)
  end

  defp select_server(healthy_servers, strategy, current_index) do
    case strategy do
      :round_robin ->
        # Use current index modulo server count
        index = rem(current_index, length(healthy_servers))
        Enum.at(healthy_servers, index)

      :random ->
        Enum.random(healthy_servers)

      :first_available ->
        hd(healthy_servers)
    end
  end

  defp update_index(_all_servers, _selected, current_index, :round_robin) do
    # Increment index for next round-robin selection
    current_index + 1
  end

  defp update_index(_all_servers, _selected, current_index, _strategy) do
    # Other strategies don't need index updates
    current_index
  end
end
