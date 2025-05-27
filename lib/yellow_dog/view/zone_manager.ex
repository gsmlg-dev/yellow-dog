defmodule YellowDog.View.ZoneManager do
  alias YellowDog.View
  use Supervisor

  def lookup(pid, name, type) do
    zone_pid =
      pid
      |> child("supervisor")
      |> View.ZoneSupervisor.match_name(name)

    IO.inspect({:lookup, pid, zone_pid, name, type})

    case zone_pid do
      nil ->
        {:nxdomain, []}

      zone_pid when is_pid(zone_pid) ->
        View.ZoneProcess.lookup(zone_pid, name, type)
    end
  end

  def child(pid, id) do
    pid
    |> Supervisor.which_children()
    |> IO.inspect()
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
    manager_pid = self()

    [
      Supervisor.child_spec({View.ZoneSupervisor, []},
        id: "supervisor"
      ),
      Supervisor.child_spec({View.ZoneRegistry, %{}},
        id: "registry"
      ),
      Supervisor.child_spec(
        {Task,
         fn ->
           if recursive do
             zone = DNS.Zone.new(".", :cache)
             IO.inspect({"Starting recursive zone at", zone})

             View.ZoneSupervisor.start_zone(
               child(manager_pid, "supervisor"),
               zone,
               nameservers: DNS.Zone.RootHint.nameservers()
             )
           end
         end},
        id: "root_zone_task"
      )
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end
end
