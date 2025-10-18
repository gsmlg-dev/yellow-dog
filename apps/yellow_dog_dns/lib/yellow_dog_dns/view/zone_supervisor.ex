defmodule YellowDogDns.View.ZoneSupervisor do
  use DynamicSupervisor

  def start_link(config) do
    DynamicSupervisor.start_link(__MODULE__, config)
  end

  def init(_config) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_zone(pid, zone) do
    DynamicSupervisor.start_child(
      pid,
      Supervisor.child_spec(
        {YellowDogDns.View.ZoneProcess, %{zone: zone, manager: self()}},
        id: zone.name
      )
    )
  end

  def start_zone(pid, zone, options) do
    DynamicSupervisor.start_child(
      pid,
      Supervisor.child_spec(
        {YellowDogDns.View.ZoneProcess, %{zone: zone, options: options, manager: self()}},
        id: zone.name
      )
    )
  end

  def terminate_zone(pid, zone) do
    DynamicSupervisor.which_children(pid)
    |> Enum.find(fn {id, pid, _type, _modules} ->
      if id == zone.name and is_pid(pid) do
        :ok = DynamicSupervisor.terminate_child(pid, id)
        true
      else
        false
      end
    end)
  end

  def match_name(nil, _name), do: nil

  def match_name(pid, _name) do
    case pid
         |> DynamicSupervisor.which_children()
         |> Enum.sort(fn {name1, _pid1, _type1, _modules1}, {name2, _pid2, _type2, _modules2} ->
           # TODO: Implement proper domain matching logic
           # For now, just sort by name string
           name1 >= name2
         end) do
      [] ->
        nil

      [{_, zone_pid, _type, _modules} | _] ->
        zone_pid
    end
  end
end
