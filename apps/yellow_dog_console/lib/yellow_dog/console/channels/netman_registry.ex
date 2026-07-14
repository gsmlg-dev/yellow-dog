defmodule YellowDog.Console.NetmanRegistry do
  @moduledoc """
  Registry of connected remote Netman service instances.

  Tracks connected clients in an ETS table and broadcasts presence
  changes via PubSub so the dashboard LiveView updates in real time.
  """

  use GenServer

  @table __MODULE__
  @pubsub YellowDog.Console.PubSub
  @topic "netman:presence"
  @max_clients 1_000

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a newly connected Netman client."
  @spec register(map()) :: :ok
  def register(client_info) do
    GenServer.cast(__MODULE__, {:register, client_info})
  end

  @doc "Update status for a connected Netman client."
  @spec update(map()) :: :ok
  def update(client_info) do
    GenServer.cast(__MODULE__, {:update, client_info})
  end

  @doc "Update last_seen timestamp for a client."
  @spec touch(String.t()) :: :ok
  def touch(node_id) do
    GenServer.cast(__MODULE__, {:touch, node_id})
  end

  @doc "Unregister a disconnected Netman client."
  @spec unregister(String.t()) :: :ok
  def unregister(node_id) do
    GenServer.cast(__MODULE__, {:unregister, node_id})
  end

  @doc "List all currently connected Netman clients."
  @spec list() :: [map()]
  def list do
    case :ets.info(@table) do
      :undefined -> []
      _ -> :ets.tab2list(@table) |> Enum.map(&elem(&1, 1))
    end
  end

  @doc "Get a specific client by node_id."
  @spec get(String.t()) :: {:ok, map()} | :error
  def get(node_id) do
    case :ets.info(@table) do
      :undefined ->
        :error

      _ ->
        case :ets.lookup(@table, node_id) do
          [{^node_id, info}] -> {:ok, info}
          _ -> :error
        end
    end
  end

  @doc "Get the count of connected clients."
  @spec count() :: non_neg_integer()
  def count do
    case :ets.info(@table) do
      :undefined -> 0
      _ -> :ets.info(@table, :size)
    end
  end

  @doc "Subscribe to presence change events."
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc false
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:register, client_info}, state) do
    with {:ok, client_info} <- normalize_client_info(client_info),
         true <- can_store_client?(client_info.node_id) do
      :ets.insert(@table, {client_info.node_id, client_info})
      broadcast({:netman_joined, client_info})
    end

    {:noreply, state}
  end

  def handle_cast({:update, client_info}, state) do
    with {:ok, client_info} <- normalize_client_info(client_info),
         true <- can_store_client?(client_info.node_id) do
      :ets.insert(@table, {client_info.node_id, client_info})
      broadcast({:netman_updated, client_info})
    end

    {:noreply, state}
  end

  def handle_cast({:touch, node_id}, state) do
    case :ets.lookup(@table, node_id) do
      [{^node_id, info}] ->
        updated = %{info | last_seen: DateTime.utc_now()}
        :ets.insert(@table, {node_id, updated})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:unregister, node_id}, state) do
    case :ets.lookup(@table, node_id) do
      [{^node_id, info}] ->
        :ets.delete(@table, node_id)
        broadcast({:netman_left, info})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, message)
  end

  defp normalize_client_info(%{node_id: node_id} = client_info)
       when is_binary(node_id) and node_id != "" and byte_size(node_id) <= 128 do
    {:ok, client_info}
  end

  defp normalize_client_info(_client_info), do: :error

  defp can_store_client?(node_id) do
    :ets.member(@table, node_id) or :ets.info(@table, :size) < @max_clients
  end
end
