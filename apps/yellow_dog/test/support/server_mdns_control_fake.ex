defmodule YellowDog.ServerMdnsControlFake do
  @moduledoc false

  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          responses: %{
            registry_snapshot: {:ok, []},
            cache_snapshot: {:ok, []},
            discovery_list: [],
            monitor_queries: [],
            clock: ~U[2026-07-17 00:00:00Z]
          },
          calls: []
        }
      end,
      name: __MODULE__
    )
  end

  def configure(responses) when is_map(responses) do
    Agent.update(__MODULE__, fn state ->
      %{state | responses: Map.merge(state.responses, responses)}
    end)
  end

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.calls), %{state | calls: []}}
    end)
  end

  def call(owner, function, arguments) do
    response =
      Agent.get_and_update(__MODULE__, fn state ->
        key = response_key(owner, function)
        value = Map.get(state.responses, key, {:error, :apply_failed})
        {value, %{state | calls: [{owner, function, arguments} | state.calls]}}
      end)

    run(response)
  end

  defp response_key(:registry, :control_snapshot), do: :registry_snapshot
  defp response_key(:registry, :control_register_service), do: :registry_register
  defp response_key(:registry, :control_update_service), do: :registry_update
  defp response_key(:registry, :control_delete_service), do: :registry_delete
  defp response_key(:registry, :control_toggle_service), do: :registry_toggle
  defp response_key(:cache, :control_snapshot), do: :cache_snapshot
  defp response_key(:cache, :control_clear), do: :cache_clear
  defp response_key(:monitor, :list_discovered_services), do: :discovery_list
  defp response_key(:monitor, :get_queries), do: :monitor_queries
  defp response_key(:clock, :utc_now), do: :clock

  defp run({:raise, reason}), do: raise(reason)
  defp run({:exit, reason}), do: exit(reason)
  defp run({:throw, reason}), do: throw(reason)
  defp run(value), do: value
end

defmodule YellowDog.ServerMdnsControlFake.Registry do
  @moduledoc false
  def control_snapshot, do: YellowDog.ServerMdnsControlFake.call(:registry, :control_snapshot, [])

  def control_register_service(service_id, service),
    do:
      YellowDog.ServerMdnsControlFake.call(:registry, :control_register_service, [
        service_id,
        service
      ])

  def control_update_service(service_id, service),
    do:
      YellowDog.ServerMdnsControlFake.call(:registry, :control_update_service, [
        service_id,
        service
      ])

  def control_delete_service(service_id),
    do: YellowDog.ServerMdnsControlFake.call(:registry, :control_delete_service, [service_id])

  def control_toggle_service(service_id, enabled),
    do:
      YellowDog.ServerMdnsControlFake.call(:registry, :control_toggle_service, [
        service_id,
        enabled
      ])
end

defmodule YellowDog.ServerMdnsControlFake.Cache do
  @moduledoc false
  def control_snapshot, do: YellowDog.ServerMdnsControlFake.call(:cache, :control_snapshot, [])
  def control_clear, do: YellowDog.ServerMdnsControlFake.call(:cache, :control_clear, [])
end

defmodule YellowDog.ServerMdnsControlFake.Monitor do
  @moduledoc false

  def list_discovered_services,
    do: YellowDog.ServerMdnsControlFake.call(:monitor, :list_discovered_services, [])

  def get_queries(opts),
    do: YellowDog.ServerMdnsControlFake.call(:monitor, :get_queries, [opts])
end

defmodule YellowDog.ServerMdnsControlFake.Clock do
  @moduledoc false
  def utc_now, do: YellowDog.ServerMdnsControlFake.call(:clock, :utc_now, [])
end
