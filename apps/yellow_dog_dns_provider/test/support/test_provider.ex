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
