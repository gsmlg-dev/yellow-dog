defmodule YellowDog.Dns.ConnectionManager do
  @moduledoc """
  DynamicSupervisor for DNS connection processes.

  Each network connection (UDP packet or TCP session) gets its own
  ConnectionProcess. The ConnectionManager:
  - Starts connection processes (called by Handler)
  - Supervises connection process lifecycle
  - Provides statistics on active connections

  ## Lifecycle

  1. Handler receives network data
  2. Handler calls `start_connection/1` to get or create connection process
  3. Handler forwards queries to connection process
  4. Connection process terminates when network connection closes
  """

  use DynamicSupervisor

  alias YellowDog.Dns.IpFormat
  alias YellowDog.Telemetry

  @doc """
  Starts the ConnectionManager supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Telemetry.info("ConnectionManager starting")
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new connection process.

  Called by the Handler when a new network connection is established.

  ## Parameters
  - `handler_pid` - PID of the Handler process
  - `client_ip` - Client IP address
  - `client_port` - Client port number
  - `opts` - Additional options

  ## Returns
  - `{:ok, pid}` - Connection process started
  - `{:error, reason}` - Failed to start
  """
  @spec start_connection(pid(), :inet.ip_address(), :inet.port_number(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_connection(handler_pid, client_ip, client_port, opts \\ []) do
    start_connection(__MODULE__, handler_pid, client_ip, client_port, opts)
  end

  @spec start_connection(
          Supervisor.supervisor(),
          pid(),
          :inet.ip_address(),
          :inet.port_number(),
          keyword()
        ) :: {:ok, pid()} | {:error, term()}
  def start_connection(supervisor, handler_pid, client_ip, client_port, opts) do
    conn_opts =
      opts
      |> Keyword.put(:handler_pid, handler_pid)
      |> Keyword.put(:client_ip, client_ip)
      |> Keyword.put(:client_port, client_port)

    child_spec = %{
      id: make_ref(),
      start: {YellowDog.Dns.ConnectionProcess, :start_link, [conn_opts]},
      restart: :temporary,
      type: :worker
    }

    # Wrap in try-catch to handle supervisor shutdown during test cleanup
    try do
      case DynamicSupervisor.start_child(supervisor, child_spec) do
        {:ok, pid} = result ->
          Telemetry.debug("Connection process started", %{
            client_ip: IpFormat.format(client_ip),
            client_port: client_port,
            pid: inspect(pid)
          })

          result

        {:error, reason} = error ->
          Telemetry.warning("Failed to start connection process", %{
            client_ip: IpFormat.format(client_ip),
            client_port: client_port,
            reason: inspect(reason)
          })

          error
      end
    catch
      :exit, {:noproc, _} ->
        # Supervisor is shutting down (common during test cleanup)
        Telemetry.debug("ConnectionManager not available (likely shutting down)")
        {:error, :manager_not_available}

      :exit, reason ->
        Telemetry.warning("ConnectionManager call failed", %{reason: inspect(reason)})
        {:error, {:exit, reason}}
    end
  end

  @doc """
  Returns statistics about active connections.
  """
  @spec stats() :: map()
  def stats do
    stats(__MODULE__)
  end

  @spec stats(Supervisor.supervisor()) :: map()
  def stats(supervisor) do
    children = DynamicSupervisor.which_children(supervisor)
    active = Enum.count(children, fn {_, pid, _, _} -> is_pid(pid) end)

    %{
      active_connections: active,
      total_children: length(children)
    }
  end

  @doc """
  Counts active connection processes.
  """
  @spec count_connections() :: non_neg_integer()
  def count_connections do
    count_connections(__MODULE__)
  end

  @spec count_connections(Supervisor.supervisor()) :: non_neg_integer()
  def count_connections(supervisor) do
    DynamicSupervisor.which_children(supervisor)
    |> Enum.count(fn {_, pid, _, _} -> is_pid(pid) end)
  end

  # Private helpers

end
