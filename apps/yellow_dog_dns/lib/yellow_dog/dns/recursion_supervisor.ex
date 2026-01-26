defmodule YellowDog.Dns.RecursionSupervisor do
  @moduledoc """
  Task supervisor for concurrent recursive DNS resolution.

  This supervisor manages short-lived `RecursionWorker` processes, each
  handling a single recursive query. Concurrency is controlled via
  `max_children` to prevent resource exhaustion during DNS amplification
  or high-load scenarios.

  ## Architecture

      RecursionSupervisor (Task.Supervisor)
      ├── max_children: N  ← concurrency limit
      └── spawns RecursionWorker per query

  ## Configuration

  - `max_children` - Maximum concurrent recursion workers (default: 100)
  - `root_servers` - Root server list passed to workers
  - `query_timeout` - Per-query timeout in milliseconds
  """

  use Supervisor

  alias YellowDog.Telemetry

  @default_max_children 100
  @default_query_timeout 5_000

  @doc """
  Starts the RecursionSupervisor.

  ## Options

  - `:view_name` - Name of the parent view (required)
  - `:max_children` - Maximum concurrent workers (default: 100)
  - `:root_servers` - Custom root server list (optional)
  - `:query_timeout` - Query timeout in ms (default: 5000)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    # Note: No via_tuple registration - the RecursionController tracks this pid
    Supervisor.start_link(__MODULE__, opts)
  end

  @doc """
  Performs recursive resolution by spawning a worker.

  Returns `{:error, :overloaded}` if the supervisor has reached max_children.
  """
  @spec resolve(String.t(), DNS.Message.t()) ::
          {:ok, DNS.Message.t()} | {:error, atom()}
  def resolve(view_name, query) do
    case get_config(view_name) do
      {:ok, config} ->
        task_sup = task_supervisor_name(view_name)
        do_resolve(task_sup, config, query)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns recursion statistics for a view.
  """
  @spec stats(String.t()) :: map()
  def stats(view_name) do
    case get_config(view_name) do
      {:ok, config} ->
        task_sup = task_supervisor_name(view_name)
        active = count_active_workers(task_sup)

        %{
          view_name: view_name,
          max_children: config.max_children,
          active_workers: active,
          query_timeout: config.query_timeout
        }

      :error ->
        %{error: :not_running}
    end
  end

  # Supervisor callbacks

  @impl true
  def init(opts) do
    view_name = Keyword.fetch!(opts, :view_name)
    max_children = Keyword.get(opts, :max_children, @default_max_children)
    query_timeout = Keyword.get(opts, :query_timeout, @default_query_timeout)
    root_servers = Keyword.get(opts, :root_servers, default_root_servers())

    # Store config in a dedicated Agent for fast lookup
    config = %{
      view_name: view_name,
      max_children: max_children,
      query_timeout: query_timeout,
      root_servers: root_servers
    }

    children = [
      # Config store (Agent)
      %{
        id: :config,
        start: {Agent, :start_link, [fn -> config end, [name: config_agent_name(view_name)]]}
      },
      # Task.Supervisor for workers
      {Task.Supervisor,
       name: task_supervisor_name(view_name), max_children: max_children, max_restarts: 0}
    ]

    Telemetry.info("RecursionSupervisor started", %{
      view: view_name,
      max_children: max_children,
      timeout: query_timeout
    })

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Private functions

  defp do_resolve(task_sup, config, query) do
    timeout = config.query_timeout * 10
    worker_opts = Map.take(config, [:root_servers, :query_timeout])

    task =
      Task.Supervisor.async_nolink(
        task_sup,
        YellowDog.Dns.RecursionWorker,
        :resolve,
        [query, worker_opts],
        shutdown: config.query_timeout + 1_000
      )

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, :max_children} ->
        {:error, :overloaded}

      {:exit, reason} ->
        Telemetry.warning("Recursion worker exited", %{reason: inspect(reason)})
        {:error, :servfail}

      nil ->
        {:error, :timeout}
    end
  end

  defp get_config(view_name) do
    try do
      config = Agent.get(config_agent_name(view_name), & &1)
      {:ok, config}
    catch
      :exit, _ -> :error
    end
  end

  defp count_active_workers(task_sup) do
    case Process.whereis(task_sup) do
      nil ->
        0

      pid ->
        %{active: active} = DynamicSupervisor.count_children(pid)
        active
    end
  end

  defp task_supervisor_name(view_name) do
    :"recursion_tasks_#{view_name}"
  end

  defp config_agent_name(view_name) do
    :"recursion_config_#{view_name}"
  end

  defp default_root_servers do
    # Root servers - a.root-servers.net through m.root-servers.net
    [
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
  end
end
