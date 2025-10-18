defmodule YellowDog.ViewManager do
  @moduledoc """
  Start a GenServer to YellowDog ViewManager.
  """

  use Supervisor

  def find_view(remote) do
    case Supervisor.which_children(__MODULE__) do
      [] ->
        {:error, :no_view}

      children ->
        case Enum.find(children, fn {_id, pid, _, _} when is_pid(pid) ->
               pid
               |> YellowDog.View.match?(remote)
             end) do
          nil -> {:error, :no_view}
          {_, pid, _, _} -> {:ok, pid}
        end
    end
  end

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  def init(_config) do
    [
      Supervisor.child_spec({YellowDog.View, %{recursive: true}},
        id: "default"
      )
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end
end
