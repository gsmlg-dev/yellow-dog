defmodule YellowDog.DnsProvider.Provider.Test do
  @moduledoc """
  In-memory stub provider for SyncEngine integration tests.
  """

  @behaviour YellowDog.DnsProvider.Provider

  @impl true
  def init(config) do
    state = %{
      zones: Map.get(config, :zones, []),
      records: Map.get(config, :records, %{}),
      read_only: Map.get(config, :read_only, false),
      apply_error: Map.get(config, :apply_error),
      apply_count: 0
    }

    {:ok, state}
  end

  @impl true
  def list_zones(state) do
    refs = Enum.map(state.zones, fn name -> %{name: name, id: nil} end)
    {:ok, refs, state}
  end

  @impl true
  def get_records(%{name: zone_name}, state) do
    records = Map.get(state.records, zone_name, [])
    {:ok, records, state}
  end

  @impl true
  def apply_changeset(_zone_ref, _changeset, %{read_only: true} = state) do
    {:error, :read_only, state}
  end

  def apply_changeset(_zone_ref, _changeset, %{apply_error: reason} = state)
      when not is_nil(reason) do
    {:error, reason, state}
  end

  def apply_changeset(%{name: zone_name}, changeset, state) do
    existing = Map.get(state.records, zone_name, [])

    deletion_keys =
      MapSet.new(changeset.deletions, fn r -> {r.owner, r.type, r.rdata} end)

    remaining =
      Enum.reject(existing, fn r ->
        MapSet.member?(deletion_keys, {r.owner, r.type, r.rdata})
      end)

    updated = remaining ++ changeset.additions

    new_state = %{
      state
      | records: Map.put(state.records, zone_name, updated),
        apply_count: state.apply_count + 1
    }

    {:ok, new_state}
  end

  @impl true
  def zone_serial(%{name: _zone_name}, state) do
    {:ok, 2_024_010_100, state}
  end
end

defmodule YellowDog.DnsProvider.LifecycleFake do
  @moduledoc false

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{configs: %{}, calls: [], responses: %{}} end, name: __MODULE__)
  end

  def configure(values), do: Agent.update(__MODULE__, &Map.merge(&1, values))

  def snapshot, do: Agent.get(__MODULE__, & &1)

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.calls), %{state | calls: []}}
    end)
  end

  def get_config(name) do
    operation(:get_config, [name], fn state ->
      result =
        case Map.fetch(state.configs, name) do
          {:ok, config} -> {:ok, config}
          :error -> {:error, :not_found}
        end

      {result, state}
    end)
  end

  def put_config(%{name: name} = config) do
    operation(:put_config, [config], fn state ->
      {:ok, %{state | configs: Map.put(state.configs, name, config)}}
    end)
  end

  def delete_config(name) do
    operation(:delete_config, [name], fn state ->
      {:ok, %{state | configs: Map.delete(state.configs, name)}}
    end)
  end

  def list_configs do
    operation(:list_configs, [], fn state ->
      {{:ok, Map.values(state.configs)}, state}
    end)
  end

  def list_conflicts(name) do
    operation(:list_conflicts, [name], fn state ->
      conflicts = state |> Map.get(:conflicts, %{}) |> Map.get(name, [])
      {{:ok, conflicts}, state}
    end)
  end

  def delete_conflict(name, conflict_id) do
    operation(:delete_conflict, [name, conflict_id], fn state ->
      conflicts =
        update_in(state, [:conflicts, name], fn entries ->
          Enum.reject(entries || [], &(Map.get(&1, :id) == conflict_id))
        end)

      {:ok, conflicts}
    end)
  end

  def reconcile(name) do
    operation(:reconcile, [name], fn state -> {:ok, state} end)
  end

  defp operation(name, args, default) do
    Agent.get_and_update(__MODULE__, fn state ->
      {response, responses} = pop_response(state.responses, name)
      {result, next_state} = if response == :default, do: default.(state), else: {response, state}
      {result, %{next_state | responses: responses, calls: [{name, args} | next_state.calls]}}
    end)
  end

  defp pop_response(responses, name) do
    case Map.get(responses, name, []) do
      [response | rest] -> {response, Map.put(responses, name, rest)}
      [] -> {:default, responses}
    end
  end
end

defmodule YellowDog.DnsProvider.ConflictFake do
  @moduledoc false

  use Agent

  @defaults %{
    configs: [],
    conflicts: %{},
    zones: %{},
    rrsets: %{},
    responses: %{}
  }

  def start_link(_opts) do
    Agent.start_link(fn -> Map.put(@defaults, :calls, []) end, name: __MODULE__)
  end

  def configure(values), do: Agent.update(__MODULE__, &Map.merge(&1, values))
  def snapshot, do: Agent.get(__MODULE__, &Map.drop(&1, [:calls]))

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.calls), %{state | calls: []}}
    end)
  end

  def operation(name, args, default) do
    Agent.get_and_update(__MODULE__, fn state ->
      {response, responses} = pop_response(state.responses, name)
      {result, next_state} = if response == :default, do: default.(state), else: {response, state}
      {result, %{next_state | responses: responses, calls: [{name, args} | next_state.calls]}}
    end)
  end

  defp pop_response(responses, name) do
    case Map.get(responses, name, []) do
      [response | rest] -> {response, Map.put(responses, name, rest)}
      [] -> {:default, responses}
    end
  end
end

defmodule YellowDog.DnsProvider.ConflictFake.Store do
  @moduledoc false

  alias YellowDog.DnsProvider.ConflictFake

  def list_configs do
    ConflictFake.operation(:list_configs, [], fn state -> {{:ok, state.configs}, state} end)
  end

  def get_config(name) do
    ConflictFake.operation(:get_config, [name], fn state ->
      result =
        case Enum.find(state.configs, &(Map.get(&1, :name) == name)) do
          nil -> {:error, :not_found}
          config -> {:ok, config}
        end

      {result, state}
    end)
  end

  def list_conflicts(name) do
    ConflictFake.operation(:list_conflicts, [name], fn state ->
      {{:ok, Map.get(state.conflicts, name, [])}, state}
    end)
  end

  def delete_conflict(name, conflict_id) do
    ConflictFake.operation(:delete_conflict, [name, conflict_id], fn state ->
      next_state =
        update_in(state, [:conflicts, name], fn conflicts ->
          Enum.reject(conflicts || [], &(Map.get(&1, :id) == conflict_id))
        end)

      {:ok, next_state}
    end)
  end
end

defmodule YellowDog.DnsProvider.ConflictFake.ZoneStore do
  @moduledoc false

  alias YellowDog.DnsProvider.ConflictFake

  def get_zone(view_name, zone_name) do
    ConflictFake.operation(:get_zone, [view_name, zone_name], fn state ->
      {{:ok, Map.get(state.zones, {view_name, zone_name}, {:error, :not_found})}, state}
    end)
  end

  def get_rrset(view_name, zone_name, owner, type) do
    ConflictFake.operation(:get_rrset, [view_name, zone_name, owner, type], fn state ->
      result =
        case Map.get(state.rrsets, {view_name, zone_name, owner, type}) do
          nil -> {:error, :not_found}
          rrset -> {:ok, %{owner: owner, type: type, rrset: rrset}}
        end

      {result, state}
    end)
  end

  def put_rrset(view_name, zone_name, owner, type, rrset) do
    ConflictFake.operation(:put_rrset, [view_name, zone_name, owner, type, rrset], fn state ->
      {:ok, put_in(state, [:rrsets, {view_name, zone_name, owner, type}], rrset)}
    end)
  end

  def delete_rrset(view_name, zone_name, owner, type) do
    ConflictFake.operation(:delete_rrset, [view_name, zone_name, owner, type], fn state ->
      {:ok, update_in(state, [:rrsets], &Map.delete(&1, {view_name, zone_name, owner, type}))}
    end)
  end
end

defmodule YellowDog.DnsProvider.ConflictFake.ZoneController do
  @moduledoc false

  alias YellowDog.DnsProvider.ConflictFake

  def reload_zone(view_name, zone_type, zone_name, options) do
    ConflictFake.operation(:reload_zone, [view_name, zone_type, zone_name, options], fn state ->
      {:ok, state}
    end)
  end
end

defmodule YellowDog.DnsProvider.ConflictFake.SyncEngine do
  @moduledoc false

  alias YellowDog.DnsProvider.ConflictFake

  def resolve_conflict(provider_name, conflict, timeout) do
    ConflictFake.operation(:resolve_conflict, [provider_name, conflict, timeout], fn state ->
      {:ok, state}
    end)
  end
end
