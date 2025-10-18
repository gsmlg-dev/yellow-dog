defmodule YellowDogDns.View.ZoneManager do
  use Supervisor

  def lookup(pid, name, type) do
    zone_pid =
      pid
      |> child("supervisor")
      |> YellowDogDns.View.ZoneSupervisor.match_name(name)

    case zone_pid do
      nil ->
        {:nxdomain, []}

      zone_pid when is_pid(zone_pid) ->
        YellowDogDns.View.ZoneProcess.lookup(zone_pid, name, type)
    end
  end

  def child(pid, id) do
    pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn {child_id, pid, _, _} ->
      if child_id == id and is_pid(pid) do
        pid
      else
        false
      end
    end)
  end

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config)
  end

  def init(%{recursive: recursive} = _config) do
    _manager_pid = self()

    [
      Supervisor.child_spec({YellowDogDns.View.ZoneSupervisor, []},
        id: "supervisor"
      ),
      Supervisor.child_spec({YellowDogDns.View.ZoneRegistry, %{}},
        id: "registry"
      ),
      Supervisor.child_spec(
        {Task,
         fn ->
           if recursive do
             # TODO: Implement recursive zone functionality
           end
         end},
        id: "root_zone_task"
      )
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end
end
