defmodule Abyss.ListenerPool do
  @moduledoc """
  Supervisor that manages a pool of UDP listener processes.

  This module creates and supervises multiple listener processes based on the
  `num_listeners` configuration. In broadcast mode, only a single listener
  is created regardless of the `num_listeners` setting.

  ## Listener Management

  - **Regular Mode**: Creates `num_listeners` separate listener processes
  - **Broadcast Mode**: Creates a single listener process for broadcast/multicast

  ## Supervision Strategy

  Uses `:one_for_one` strategy so that if one listener crashes,
  other listeners continue to operate normally.

  This module is primarily used internally by `Abyss.Server`.
  """

  use Supervisor

  @doc """
  Start the listener pool supervisor.

  ## Parameters
  - `arg` - Tuple containing `{server_pid, server_config}`

  ## Returns
  - Standard Supervisor start result
  """
  @spec start_link({server_pid :: pid, Abyss.ServerConfig.t()}) :: Supervisor.on_start()
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg)
  end

  @doc """
  Get PIDs of all active listener processes in the pool.

  ## Parameters
  - `supervisor` - The listener pool supervisor PID

  ## Returns
  - List of listener PIDs, empty list if supervisor is not alive
  """
  @spec listener_pids(Supervisor.supervisor()) :: [pid()]
  def listener_pids(supervisor) do
    try do
      case Process.alive?(supervisor) do
        false ->
          []

        true ->
          supervisor
          |> Supervisor.which_children()
          |> Enum.reduce([], fn
            {_, listener_pid, _, _}, acc when is_pid(listener_pid) -> [listener_pid | acc]
            _, acc -> acc
          end)
      end
    rescue
      ArgumentError -> []
      _ -> []
    end
  end

  @doc """
  Suspend the listener pool by stopping all listener processes.

  This stops the acceptance of new connections but doesn't affect
  existing connections.

  ## Parameters
  - `pid` - The listener pool supervisor PID

  ## Returns
  - `:ok` if suspend was successful, `:error` if supervisor is not alive
  """
  @spec suspend(Supervisor.supervisor()) :: :ok | :error
  def suspend(pid) do
    try do
      case Process.alive?(pid) do
        false ->
          :error

        true ->
          pid
          |> listener_pids()
          |> Enum.each(&Process.exit(&1, :normal))

          :ok
      end
    rescue
      ArgumentError -> :error
      _ -> :error
    end
  end

  @doc """
  Resume the listener pool by sending start messages to all listener processes.

  ## Parameters
  - `pid` - The listener pool supervisor PID

  ## Returns
  - `:ok` if resume was successful, `:error` if supervisor is not alive
  """
  @spec resume(Supervisor.supervisor()) :: :ok | :error
  def resume(pid) do
    try do
      case Process.alive?(pid) do
        false ->
          :error

        true ->
          # Send resume message to all listeners
          pid
          |> listener_pids()
          |> Enum.each(&send(&1, :start_listening))

          :ok
      end
    rescue
      ArgumentError -> :error
      _ -> :error
    end
  end

  @doc """
  Send start listening message to all listener processes.

  This is typically used during server startup to trigger listeners
  to begin accepting connections.

  ## Parameters
  - `pid` - The listener pool supervisor PID
  """
  @spec start_listening(Supervisor.supervisor()) :: :ok
  def start_listening(pid) do
    pid
    |> listener_pids()
    |> Enum.each(&send(&1, :start_listening))
  end

  @impl Supervisor
  @spec init({server_pid :: pid, Abyss.ServerConfig.t()}) ::
          {:ok,
           {Supervisor.sup_flags(),
            [Supervisor.child_spec() | (old_erlang_child_spec :: :supervisor.child_spec())]}}
  def init(
        {server_pid, %Abyss.ServerConfig{num_listeners: num_listeners, broadcast: false} = config}
      ) do
    1..num_listeners
    |> Enum.map(
      &Supervisor.child_spec({Abyss.Listener, {"listener-#{&1}", server_pid, config}},
        id: "listener-#{&1}"
      )
    )
    |> Supervisor.init(strategy: :one_for_one)
  end

  def init({server_pid, %Abyss.ServerConfig{num_listeners: _, broadcast: true} = config}) do
    [
      Supervisor.child_spec({Abyss.Listener, {"listener-broadcast", server_pid, config}},
        id: "listener-broadcast"
      )
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end
end
