defmodule YellowDog.Dns.RecursionController do
  @moduledoc """
  Facade for recursive DNS resolution with concurrent worker pool.

  The RecursionController provides the public API for recursive resolution
  while delegating actual work to `RecursionSupervisor` and `RecursionWorker`.
  This enables concurrent resolution of multiple queries while maintaining
  statistics and backward compatibility.

  ## Architecture

      RecursionController (GenServer - facade)
      └── RecursionSupervisor (Supervisor)
          ├── Config Agent
          └── Task.Supervisor
              └── RecursionWorker (short-lived tasks)

  ## Resolution Process

  1. Start with root hints (root nameservers)
  2. Query root server for TLD nameservers
  3. Query TLD server for authoritative nameservers
  4. Query authoritative server for final answer
  5. Follow referrals until answer is found or max depth reached

  ## Features

  - Concurrent resolution (multiple queries in parallel)
  - Concurrency limiting via max_children
  - Referral following
  - Glue record handling
  - Query depth limiting
  """

  use GenServer

  alias YellowDog.Telemetry
  alias YellowDog.Dns.RecursionSupervisor
  alias DNS.Message

  @default_max_children 100
  @default_query_timeout 5_000
  @default_root_servers [
    # Root servers - a.root-servers.net through m.root-servers.net
    {{198, 41, 0, 4}, 53},
    {{199, 9, 14, 201}, 53},
    {{192, 33, 4, 12}, 53},
    {{199, 7, 91, 13}, 53},
    {{192, 203, 230, 10}, 53},
    {{192, 5, 5, 241}, 53},
    {{192, 112, 36, 4}, 53},
    {{198, 97, 190, 53}, 53},
    {{192, 36, 148, 17}, 53},
    {{192, 58, 128, 30}, 53},
    {{193, 0, 14, 129}, 53},
    {{199, 7, 83, 42}, 53},
    {{202, 12, 27, 33}, 53}
  ]

  defstruct [
    :view_name,
    :supervisor_pid,
    :max_children,
    :query_timeout,
    :root_servers,
    query_count: 0,
    success_count: 0,
    error_count: 0,
    overload_count: 0
  ]

  # Client API

  @doc """
  Starts a RecursionController.

  ## Options

  - `:view_name` - Name of the parent view (required)
  - `:max_children` - Maximum concurrent workers (default: 100)
  - `:root_servers` - Custom root server list (optional)
  - `:query_timeout` - Query timeout in ms (default: 5000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    view_name = Keyword.get(opts, :view_name, "default")
    GenServer.start_link(__MODULE__, opts, name: via_tuple(view_name))
  end

  @doc """
  Performs recursive resolution for a query.

  Resolution is performed by a worker process under the supervisor.
  Returns `{:error, :overloaded}` if max_children is reached.
  """
  @spec resolve(pid(), Message.t()) :: {:ok, Message.t()} | {:error, atom()}
  def resolve(pid, query) do
    GenServer.call(pid, {:resolve, query}, :infinity)
  end

  @doc """
  Returns recursion controller statistics.
  """
  @spec stats(pid()) :: map()
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  @doc """
  Returns the supervisor PID for this controller.
  """
  @spec get_supervisor(pid()) :: pid() | nil
  def get_supervisor(pid) do
    GenServer.call(pid, :get_supervisor)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    view_name = Keyword.get(opts, :view_name, "default")
    max_children = Keyword.get(opts, :max_children, @default_max_children)
    query_timeout = Keyword.get(opts, :query_timeout, @default_query_timeout)
    root_servers = Keyword.get(opts, :root_servers, @default_root_servers)

    # Start the RecursionSupervisor as a child
    supervisor_opts = [
      view_name: view_name,
      max_children: max_children,
      query_timeout: query_timeout,
      root_servers: root_servers
    ]

    {:ok, supervisor_pid} = RecursionSupervisor.start_link(supervisor_opts)

    state = %__MODULE__{
      view_name: view_name,
      supervisor_pid: supervisor_pid,
      max_children: max_children,
      query_timeout: query_timeout,
      root_servers: root_servers
    }

    Telemetry.info("RecursionController started", %{
      view: view_name,
      max_children: max_children,
      timeout: query_timeout
    })

    {:ok, state}
  end

  @impl true
  def handle_call({:resolve, query}, _from, state) do
    state = %{state | query_count: state.query_count + 1}

    # Delegate to supervisor
    case RecursionSupervisor.resolve(state.view_name, query) do
      {:ok, response} ->
        state = %{state | success_count: state.success_count + 1}
        {:reply, {:ok, response}, state}

      {:error, :overloaded} ->
        state = %{state | overload_count: state.overload_count + 1, error_count: state.error_count + 1}
        Telemetry.warning("Recursion pool overloaded", %{view: state.view_name})
        {:reply, {:error, :overloaded}, state}

      {:error, reason} ->
        state = %{state | error_count: state.error_count + 1}
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    # Get active worker count from supervisor
    supervisor_stats = RecursionSupervisor.stats(state.view_name)
    active_workers = Map.get(supervisor_stats, :active_workers, 0)

    stats = %{
      view_name: state.view_name,
      max_children: state.max_children,
      active_workers: active_workers,
      query_count: state.query_count,
      success_count: state.success_count,
      error_count: state.error_count,
      overload_count: state.overload_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:get_supervisor, _from, state) do
    {:reply, state.supervisor_pid, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Stop the supervisor
    if state.supervisor_pid && Process.alive?(state.supervisor_pid) do
      Supervisor.stop(state.supervisor_pid)
    end

    :ok
  end

  # Private Functions

  defp via_tuple(view_name) do
    {:via, Registry, {YellowDog.Dns.RecursionRegistry, view_name}}
  end
end
