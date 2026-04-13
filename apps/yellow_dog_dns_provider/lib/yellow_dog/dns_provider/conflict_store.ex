defmodule YellowDog.DnsProvider.ConflictStore do
  @moduledoc """
  In-memory ETS cache for sync conflicts, warmed from Store on boot.

  Provides fast read access to conflicts without hitting the Store
  backend on every query. Writes go through `Store.Provider` and
  are reflected here via `put_conflict/1`.
  """

  use GenServer

  require Logger

  @table :dns_provider_conflicts

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    warm_from_store()
    {:ok, %{}}
  end

  @doc "List all conflicts for a given provider."
  @spec list_conflicts(String.t()) :: [map()]
  def list_conflicts(provider_name) do
    :ets.match_object(@table, {{provider_name, :_}, :_})
    |> Enum.map(fn {_key, conflict} -> conflict end)
  end

  @doc "Insert or update a conflict in the ETS cache."
  @spec put_conflict(map()) :: :ok
  def put_conflict(%{provider_name: name, id: id} = conflict) do
    :ets.insert(@table, {{name, id}, conflict})
    :ok
  end

  @doc "Remove a conflict from the ETS cache."
  @spec delete_conflict(String.t(), String.t()) :: :ok
  def delete_conflict(provider_name, conflict_id) do
    :ets.delete(@table, {provider_name, conflict_id})
    :ok
  end

  defp warm_from_store do
    case YellowDog.Store.Provider.list_configs() do
      {:ok, configs} ->
        Enum.each(configs, fn config ->
          name = Map.get(config, :name, "")

          case YellowDog.Store.Provider.list_conflicts(name) do
            {:ok, conflicts} -> Enum.each(conflicts, &put_conflict/1)
            _ -> :ok
          end
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
