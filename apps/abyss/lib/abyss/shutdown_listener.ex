defmodule Abyss.ShutdownListener do
  @moduledoc """
  Coordinates graceful shutdown of an Abyss server instance.

  This module is part of the Abyss supervision tree and is responsible for
  stopping the listener process early in the shutdown process to allow
  existing connections to drain without accepting new ones.

  ## Shutdown Process

  1. Server receives shutdown signal
  2. ShutdownListener terminates first (due to supervision strategy)
  3. It suspends the listener pool via `Abyss.ListenerPool.suspend/1`
  4. This stops accepting new connections immediately
  5. Existing connections continue to process until they finish
  6. Eventually the entire server shuts down gracefully

  ## Benefits

  - **Immediate Connection Stop**: No new connections are accepted
  - **Graceful Drain**: Existing connections can finish their work
  - **Resource Cleanup**: Proper cleanup of all resources
  - **No Request Loss**: In-flight requests are not abruptly terminated

  This module is primarily used internally by `Abyss.Server`.
  """

  # Used as part of the `Abyss.Server` supervision tree to facilitate
  # stopping the server's listener process early in the shutdown process, in order
  # to allow existing connections to drain without accepting new ones

  use GenServer

  @typedoc """
  Internal state of the shutdown listener process.
  """
  @type state :: %{
          optional(:server_pid) => pid(),
          optional(:listener_pool_pid) => pid() | nil
        }

  @doc """
  Start the shutdown listener process.

  ## Parameters
  - `server_pid` - PID of the server supervisor

  ## Returns
  - Standard GenServer start result
  """
  @spec start_link(pid()) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(server_pid) do
    GenServer.start_link(__MODULE__, server_pid)
  end

  @doc """
  Initialize the shutdown listener.

  Sets up process to trap exit signals and schedules the listener pool
  PID lookup via continue pattern.

  ## Parameters
  - `server_pid` - PID of the server supervisor

  ## Returns
  - `{:ok, state, {:continue, :setup_listener_pool_pid}}`
  """
  @impl true
  @spec init(pid()) :: {:ok, state, {:continue, :setup_listener_pool_pid}}
  def init(server_pid) do
    Process.flag(:trap_exit, true)
    {:ok, %{server_pid: server_pid}, {:continue, :setup_listener_pool_pid}}
  end

  @doc """
  Handle the setup continuation by looking up the listener pool PID.

  ## Parameters
  - `:setup_listener_pool_pid` - The continuation action
  - `state` - Current process state

  ## Returns
  - `{:noreply, updated_state}` with listener_pool_pid set
  """
  @impl true
  @spec handle_continue(:setup_listener_pool_pid, state) :: {:noreply, state}
  def handle_continue(:setup_listener_pool_pid, %{server_pid: server_pid} = state) do
    listener_pool_pid = Abyss.Server.listener_pool_pid(server_pid)
    {:noreply, state |> Map.put(:listener_pool_pid, listener_pool_pid)}
  end

  @doc """
  Handle process termination by suspending the listener pool.

  This is called during server shutdown and triggers the graceful shutdown
  process by stopping new connections while allowing existing ones to finish.

  ## Parameters
  - `reason` - The termination reason
  - `state` - Current process state containing listener_pool_pid

  ## Returns
  - `:ok`
  """
  @impl true
  @spec terminate(reason, state) :: :ok
        when reason: :normal | :shutdown | {:shutdown, term} | term
  def terminate(_reason, %{listener_pool_pid: listener_pool_pid}) do
    Abyss.ListenerPool.suspend(listener_pool_pid)
  end

  @impl true
  @spec terminate(reason, state) :: :ok
        when reason: :normal | :shutdown | {:shutdown, term} | term
  def terminate(_reason, _state), do: :ok
end
