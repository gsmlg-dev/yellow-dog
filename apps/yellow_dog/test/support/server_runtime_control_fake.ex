defmodule YellowDog.ServerRuntimeControlFake do
  @moduledoc false

  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          services: [
            %{name: :dns, controllable?: true, available?: true},
            %{name: :server_agent, controllable?: true, available?: false}
          ],
          statuses: %{
            dns: %{enabled: true, running: true, pid: self(), config: %{secret: "hidden"}},
            server_agent: %{enabled: true, running: false, pid: self(), config: %{path: "/tmp"}}
          },
          stats: %{dns: %{}, server_agent: %{error: "unavailable"}},
          start_result: :ok,
          stop_result: :ok,
          calls: []
        }
      end,
      name: __MODULE__
    )
  end

  def configure(overrides) when is_map(overrides) do
    Agent.update(__MODULE__, &Map.merge(&1, overrides))
  end

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.calls), %{state | calls: []}}
    end)
  end

  def services, do: Agent.get(__MODULE__, & &1.services)

  def fetch_service(service) do
    Agent.get(__MODULE__, fn state ->
      case Enum.find(state.services, &(&1.name == service)) do
        nil -> :error
        metadata -> {:ok, metadata}
      end
    end)
  end

  def statuses, do: Agent.get(__MODULE__, & &1.statuses)

  def status(service),
    do: Agent.get(__MODULE__, &Map.get(&1.statuses, service, %{error: "Unknown service"}))

  def stats(service),
    do: Agent.get(__MODULE__, &Map.get(&1.stats, service, %{error: "Unknown service"}))

  def start(service) do
    run_control(:start, service, :start_result, %{enabled: true, running: true})
  end

  def stop(service) do
    run_control(:stop, service, :stop_result, %{enabled: false, running: false})
  end

  defp run_control(action, service, result_key, status) do
    result =
      Agent.get_and_update(__MODULE__, fn state ->
        result = Map.fetch!(state, result_key)
        next_state = %{state | calls: [{action, service} | state.calls]}

        next_state =
          if result == :ok do
            update_in(next_state, [:statuses, service], fn current ->
              Map.merge(current || %{}, status)
            end)
          else
            next_state
          end

        {result, next_state}
      end)

    run(result)
  end

  defp run({:raise, reason}), do: raise(reason)
  defp run({:throw, reason}), do: throw(reason)
  defp run({:exit, reason}), do: exit(reason)
  defp run(result), do: result
end

defmodule YellowDog.ServerRuntimeControlFake.ServiceManager do
  @moduledoc false

  def get_all_status, do: YellowDog.ServerRuntimeControlFake.statuses()
  def get_service_status(service), do: YellowDog.ServerRuntimeControlFake.status(service)
  def get_service_stats(service), do: YellowDog.ServerRuntimeControlFake.stats(service)
  def start_service(service), do: YellowDog.ServerRuntimeControlFake.start(service)
  def stop_service(service), do: YellowDog.ServerRuntimeControlFake.stop(service)
end

defmodule YellowDog.ServerRuntimeControlFake.ServiceRegistry do
  @moduledoc false

  def all, do: YellowDog.ServerRuntimeControlFake.services()
  def fetch(service), do: YellowDog.ServerRuntimeControlFake.fetch_service(service)
end

defmodule YellowDog.ServerRuntimeControlFake.Application do
  @moduledoc false

  def start_service_supervisor(service, _supervisor),
    do: YellowDog.ServerRuntimeControlFake.start(service)

  def stop_service_supervisor(service, _supervisor),
    do: YellowDog.ServerRuntimeControlFake.stop(service)
end
