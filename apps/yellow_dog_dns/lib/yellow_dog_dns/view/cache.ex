defmodule YellowDogDns.View.Cache do
  use Agent

  def start_link(init_cache) do
    Agent.start_link(fn -> init_cache end)
  end

  def get(pid, name) do
    Agent.get(pid, fn state -> Map.get(state, name) end)
  end

  def put(pid, name, value) do
    Agent.update(pid, fn state -> Map.put(state, name, value) end)
  end
end
