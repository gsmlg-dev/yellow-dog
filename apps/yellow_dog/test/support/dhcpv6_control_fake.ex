defmodule YellowDog.Dhcpv6ControlFake do
  @moduledoc false

  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          pools: [],
          prepared_pool: nil,
          leases: [],
          status: {:ok, :running},
          save_pool: :ok,
          remove_pool: :ok,
          apply_pools: :ok,
          calls: []
        }
      end,
      name: __MODULE__
    )
  end

  def configure(options) do
    Agent.update(__MODULE__, fn state ->
      Enum.reduce(options, state, fn {key, value}, state -> Map.put(state, key, value) end)
    end)
  end

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.calls), %{state | calls: []}}
    end)
  end

  def pool_store_call(function, arguments) do
    Agent.get_and_update(__MODULE__, fn state ->
      {result, state} =
        case {function, arguments} do
          {:control_snapshot, []} -> {{:ok, state.pools}, state}
          {:control_validate_pool, [_pool]} -> {:ok, state}
          {:control_persist_snapshot, [_pools]} -> consume(state, :save_pool, :ok)
        end

      {result, %{state | calls: [{:pool_store, function, arguments} | state.calls]}}
    end)
  end

  def lease_manager_call(function, arguments) do
    Agent.get_and_update(__MODULE__, fn state ->
      {result, state} =
        case {function, arguments} do
          {:control_pool_snapshot, []} ->
            {{:ok, state.pools}, state}

          {:control_apply_pool_snapshot, [_pools]} ->
            consume(state, :apply_pools, :ok)

          {:control_pool_has_active_leases?, [pool_id]} ->
            {{:ok, Enum.any?(state.leases, &(&1.pool_name == pool_id))}, state}

          {:control_list_leases, []} ->
            {{:ok, state.leases}, state}

          {:control_status, []} ->
            {state.status, state}

          {:control_release_lease, [lease_id]} ->
            case Enum.find(state.leases, &(&1.lease_id == lease_id)) do
              nil -> {{:error, :not_found}, state}
              lease -> {{:ok, lease}, state}
            end
        end

      {result, %{state | calls: [{:lease_manager, function, arguments} | state.calls]}}
    end)
  end

  defp consume(state, key, default) do
    case Map.get(state, key, default) do
      [result | rest] -> {result, Map.put(state, key, rest)}
      result -> {result, state}
    end
  end
end

defmodule YellowDog.Dhcpv6ControlFake.PoolStore do
  @moduledoc false

  def control_snapshot, do: YellowDog.Dhcpv6ControlFake.pool_store_call(:control_snapshot, [])

  def control_validate_pool(pool),
    do: YellowDog.Dhcpv6ControlFake.pool_store_call(:control_validate_pool, [pool])

  def control_persist_snapshot(pools),
    do: YellowDog.Dhcpv6ControlFake.pool_store_call(:control_persist_snapshot, [pools])
end

defmodule YellowDog.Dhcpv6ControlFake.LeaseManager do
  @moduledoc false

  def control_pool_snapshot,
    do: YellowDog.Dhcpv6ControlFake.lease_manager_call(:control_pool_snapshot, [])

  def control_apply_pool_snapshot(pools),
    do: YellowDog.Dhcpv6ControlFake.lease_manager_call(:control_apply_pool_snapshot, [pools])

  def control_pool_has_active_leases?(pool_id),
    do:
      YellowDog.Dhcpv6ControlFake.lease_manager_call(:control_pool_has_active_leases?, [pool_id])

  def control_list_leases,
    do: YellowDog.Dhcpv6ControlFake.lease_manager_call(:control_list_leases, [])

  def control_status, do: YellowDog.Dhcpv6ControlFake.lease_manager_call(:control_status, [])

  def control_release_lease(lease_id),
    do: YellowDog.Dhcpv6ControlFake.lease_manager_call(:control_release_lease, [lease_id])
end
