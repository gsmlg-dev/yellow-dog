defmodule YellowDog.ServerDhcpv4ControlFake do
  @moduledoc false

  use Agent

  @defaults %{
    pools: [],
    runtime_pools: [],
    leases: [],
    active_pools: MapSet.new(),
    status: :running,
    responses: %{}
  }

  def start_link(_opts) do
    Agent.start_link(fn -> Map.put(@defaults, :calls, []) end, name: __MODULE__)
  end

  def configure(values) when is_map(values), do: Agent.update(__MODULE__, &Map.merge(&1, values))

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.calls), %{state | calls: []}}
    end)
  end

  def snapshot, do: Agent.get(__MODULE__, &Map.drop(&1, [:calls]))

  def fetch(key, call, default) do
    Agent.get_and_update(__MODULE__, fn state ->
      {response, responses} = pop_response(state.responses, key)
      {result, next_state} = if response == :default, do: default.(state), else: {response, state}
      {result, %{next_state | responses: responses, calls: [call | next_state.calls]}}
    end)
  end

  def update(key, call, default) do
    Agent.get_and_update(__MODULE__, fn state ->
      {response, responses} = pop_response(state.responses, key)
      {result, next_state} = if response == :default, do: default.(state), else: {response, state}
      {result, %{next_state | responses: responses, calls: [call | next_state.calls]}}
    end)
  end

  defp pop_response(responses, key) do
    case Map.get(responses, key, []) do
      [response | rest] -> {response, Map.put(responses, key, rest)}
      _ -> {:default, responses}
    end
  end
end

defmodule YellowDog.ServerDhcpv4ControlFake.PoolStore do
  @moduledoc false

  def control_snapshot do
    YellowDog.ServerDhcpv4ControlFake.fetch(
      :snapshot,
      {:pool_store, :control_snapshot, []},
      fn state ->
        {{:ok, state.pools}, state}
      end
    )
  end

  def control_validate_pool(pool) do
    YellowDog.ServerDhcpv4ControlFake.fetch(
      :validate,
      {:pool_store, :control_validate_pool, [pool]},
      fn state ->
        {:ok, state}
      end
    )
  end

  def control_persist_snapshot(pools) do
    YellowDog.ServerDhcpv4ControlFake.update(
      :persist,
      {:pool_store, :control_persist_snapshot, [pools]},
      fn state ->
        {:ok, %{state | pools: pools}}
      end
    )
  end
end

defmodule YellowDog.ServerDhcpv4ControlFake.LeaseManager do
  @moduledoc false

  def control_pool_snapshot do
    YellowDog.ServerDhcpv4ControlFake.fetch(
      :runtime_snapshot,
      {:lease_manager, :control_pool_snapshot, []},
      fn state ->
        {{:ok, state.runtime_pools}, state}
      end
    )
  end

  def control_apply_pool_snapshot(pools) do
    YellowDog.ServerDhcpv4ControlFake.update(
      :apply,
      {:lease_manager, :control_apply_pool_snapshot, [pools]},
      fn state ->
        {:ok, %{state | runtime_pools: pools}}
      end
    )
  end

  def control_pool_has_active_leases?(pool_id) do
    YellowDog.ServerDhcpv4ControlFake.fetch(
      :active,
      {:lease_manager, :control_pool_has_active_leases?, [pool_id]},
      fn state ->
        {{:ok, MapSet.member?(state.active_pools, pool_id)}, state}
      end
    )
  end

  def control_list_leases do
    YellowDog.ServerDhcpv4ControlFake.fetch(
      :leases,
      {:lease_manager, :control_list_leases, []},
      fn state ->
        {{:ok, state.leases}, state}
      end
    )
  end

  def control_release_lease(lease_id) do
    YellowDog.ServerDhcpv4ControlFake.update(
      :release,
      {:lease_manager, :control_release_lease, [lease_id]},
      fn state ->
        case Enum.find(state.leases, &(&1.lease_id == lease_id)) do
          nil ->
            {{:error, :not_found}, state}

          lease ->
            {{:ok, lease},
             %{state | leases: Enum.reject(state.leases, &(&1.lease_id == lease_id))}}
        end
      end
    )
  end

  def control_status do
    YellowDog.ServerDhcpv4ControlFake.fetch(
      :status,
      {:lease_manager, :control_status, []},
      fn state ->
        {{:ok, state.status}, state}
      end
    )
  end
end

defmodule YellowDog.ServerDhcpv4ControlFake.Clock do
  @moduledoc false

  def utc_now do
    YellowDog.ServerDhcpv4ControlFake.fetch(:clock, {:clock, :utc_now, []}, fn state ->
      {~U[2026-07-17 00:00:00Z], state}
    end)
  end
end
