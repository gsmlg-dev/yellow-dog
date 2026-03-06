defmodule YellowDog.Netman.Connection.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-interface Connection FSM processes.
  """

  use DynamicSupervisor

  alias YellowDog.Netman.Connection.FSM

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a connection FSM for an interface with a profile."
  @spec start_connection(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def start_connection(interface, profile) do
    spec = {FSM, [interface: interface, profile: profile]}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  @doc "Stop a connection FSM for an interface."
  @spec stop_connection(String.t()) :: :ok | {:error, :not_found}
  def stop_connection(interface) do
    case find_connection(interface) do
      {:ok, pid} ->
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc "List all active connections."
  @spec list_connections() :: [map()]
  def list_connections do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        case FSM.get_state(pid) do
          {:ok, state} -> [state]
          _ -> []
        end

      _ ->
        []
    end)
  end

  @doc "Find a connection FSM by interface name."
  @spec find_connection(String.t()) :: {:ok, pid()} | :error
  def find_connection(interface) do
    case Registry.lookup(YellowDog.Netman.Registry, {:connection, interface}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Find a connection FSM by profile ID."
  @spec find_connection_by_profile(String.t()) :: {:ok, pid()} | :error
  def find_connection_by_profile(profile_id) do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.find_value(:error, fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        case FSM.get_state(pid) do
          {:ok, %{profile_id: ^profile_id}} -> {:ok, pid}
          _ -> nil
        end

      _ ->
        nil
    end)
  end
end
