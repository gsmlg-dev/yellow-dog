defmodule YellowDog.Store.SingleNode do
  @moduledoc """
  Single-node mode detection and ETS-based backend for the Store facade.

  When YellowDog detects a single-node deployment (no cluster peers), the Store
  facade can bypass Raft consensus and write directly to a local ETS table.
  This eliminates Raft overhead for standalone home/office deployments while
  keeping the same API surface.

  The mode is detected at startup and can switch dynamically if peers join or leave.
  All consistency level parameters are accepted but ignored in single-node mode.
  """

  use GenServer
  require Logger

  @table :yellow_dog_store_single_node
  @check_interval_ms 30_000

  defstruct mode: :single_node, peer_count: 0

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns true if the Store should operate in single-node (ETS) mode."
  @spec single_node?() :: boolean()
  def single_node? do
    :persistent_term.get({__MODULE__, :mode}, :single_node) == :single_node
  end

  @doc "Returns the current mode: :single_node or :cluster."
  @spec mode() :: :single_node | :cluster
  def mode do
    :persistent_term.get({__MODULE__, :mode}, :single_node)
  end

  # ETS-backed operations for single-node mode

  @spec put(String.t(), term(), keyword()) :: :ok
  def put(key, value, opts \\ []) do
    ensure_table()
    ttl = Keyword.get(opts, :ttl)
    expires_at = if ttl, do: System.system_time(:second) + ttl, else: nil
    :ets.insert(@table, {key, value, expires_at})
    :ok
  end

  @spec get(String.t(), keyword()) :: {:ok, term()} | {:error, :not_found}
  def get(key, _opts \\ []) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if expired?(expires_at) do
          :ets.delete(@table, key)
          {:error, :not_found}
        else
          {:ok, value}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  end

  @spec put_if(String.t(), term(), keyword()) :: :ok | {:error, :condition_failed}
  def put_if(key, value, opts \\ []) do
    ensure_table()

    case Keyword.get(opts, :condition) do
      nil ->
        expected = Keyword.get(opts, :expected)
        current = ets_get(key)

        if current == expected do
          ttl = Keyword.get(opts, :ttl)
          expires_at = if ttl, do: System.system_time(:second) + ttl, else: nil
          :ets.insert(@table, {key, value, expires_at})
          :ok
        else
          {:error, :condition_failed}
        end

      condition_fn when is_function(condition_fn, 1) ->
        current = ets_get(key)

        case condition_fn.(current) do
          true ->
            ttl = Keyword.get(opts, :ttl)
            expires_at = if ttl, do: System.system_time(:second) + ttl, else: nil
            :ets.insert(@table, {key, value, expires_at})
            :ok

          {:update, new_value} ->
            ttl = Keyword.get(opts, :ttl)
            expires_at = if ttl, do: System.system_time(:second) + ttl, else: nil
            :ets.insert(@table, {key, new_value, expires_at})
            :ok

          {:update, new_value, ttl_opts} ->
            ttl = Keyword.get(ttl_opts, :ttl, Keyword.get(opts, :ttl))
            expires_at = if ttl, do: System.system_time(:second) + ttl, else: nil
            :ets.insert(@table, {key, new_value, expires_at})
            :ok

          false ->
            {:error, :condition_failed}
        end
    end
  end

  @spec prefix_scan(String.t(), keyword()) :: {:ok, [{String.t(), term()}]}
  def prefix_scan(prefix, _opts \\ []) do
    ensure_table()
    now = System.system_time(:second)

    results =
      :ets.foldl(
        fn {key, value, expires_at}, acc ->
          if String.starts_with?(key, prefix) and not expired?(expires_at, now) do
            [{key, value} | acc]
          else
            acc
          end
        end,
        [],
        @table
      )

    {:ok, Enum.sort_by(results, fn {key, _} -> key end)}
  end

  @spec put_many(list()) :: {:ok, map()}
  def put_many(operations) do
    ensure_table()

    results =
      Enum.into(operations, %{}, fn
        {key, value} ->
          put(key, value)
          {key, :ok}

        {key, value, ttl} ->
          put(key, value, ttl: ttl)
          {key, :ok}
      end)

    {:ok, results}
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    ensure_table()
    mode = detect_mode()
    :persistent_term.put({__MODULE__, :mode}, mode)
    schedule_check()
    {:ok, %__MODULE__{mode: mode, peer_count: peer_count()}}
  end

  @impl true
  def handle_info(:check_peers, state) do
    new_mode = detect_mode()
    old_mode = state.mode

    if new_mode != old_mode do
      Logger.info("Store mode changed: #{old_mode} -> #{new_mode}")
      :persistent_term.put({__MODULE__, :mode}, new_mode)
    end

    schedule_check()
    {:noreply, %{state | mode: new_mode, peer_count: peer_count()}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp detect_mode do
    if peer_count() > 0, do: :cluster, else: :single_node
  end

  defp peer_count do
    length(Node.list())
  end

  defp schedule_check do
    Process.send_after(self(), :check_peers, @check_interval_ms)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        :ok

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp ets_get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if expired?(expires_at) do
          :ets.delete(@table, key)
          nil
        else
          value
        end

      [] ->
        nil
    end
  end

  defp expired?(nil), do: false
  defp expired?(expires_at), do: System.system_time(:second) >= expires_at

  defp expired?(nil, _now), do: false
  defp expired?(expires_at, now), do: now >= expires_at
end
