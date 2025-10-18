defmodule YellowDogDns.View.ZoneRegistry do
  use Agent

  def start_link(zones) do
    Agent.start_link(fn -> zones end)
  end

  def add_zone(pid, zone) do
    Agent.get(pid, fn zones -> [zone | zones] end)
  end

  def remove_zone(pid, zone) do
    Agent.update(pid, fn zones -> zones |> Enum.filter(fn z -> z != zone end) end)
  end
end
