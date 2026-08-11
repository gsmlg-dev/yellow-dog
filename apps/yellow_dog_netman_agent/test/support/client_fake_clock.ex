defmodule YellowDog.NetmanAgent.ClientFakeMonotonicClock do
  @moduledoc false

  def configure(values) when is_list(values) and values != [] do
    {:ok, agent} = Agent.start_link(fn -> values end)
    :persistent_term.put({__MODULE__, :state}, agent)
    agent
  end

  def now do
    Agent.get_and_update(state(), fn
      [value] -> {value, [value]}
      [value | rest] -> {value, rest}
    end)
  end

  def clear do
    case :persistent_term.get({__MODULE__, :state}, nil) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: Agent.stop(pid)

      _other ->
        :ok
    end

    :persistent_term.erase({__MODULE__, :state})
  end

  defp state, do: :persistent_term.get({__MODULE__, :state})
end

defmodule YellowDog.NetmanAgent.ClientFakeWallClock do
  @moduledoc false

  def configure(values) when is_list(values) and values != [] do
    {:ok, agent} = Agent.start_link(fn -> values end)
    :persistent_term.put({__MODULE__, :state}, agent)
    agent
  end

  def now do
    Agent.get_and_update(state(), fn
      [value] -> {value, [value]}
      [value | rest] -> {value, rest}
    end)
  end

  def clear do
    case :persistent_term.get({__MODULE__, :state}, nil) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: Agent.stop(pid)

      _other ->
        :ok
    end

    :persistent_term.erase({__MODULE__, :state})
  end

  defp state, do: :persistent_term.get({__MODULE__, :state})
end
