defmodule YellowDogCore.Config do
  use Agent

  def start_link(config) do
    Agent.start_link(fn -> config end, name: __MODULE__)
  end

  def get_all do
    Agent.get(__MODULE__, fn state -> state end)
  end

  def get(name) do
    Agent.get(__MODULE__, fn state -> Map.get(state, name) end)
  end
end
