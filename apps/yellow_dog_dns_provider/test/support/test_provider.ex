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
