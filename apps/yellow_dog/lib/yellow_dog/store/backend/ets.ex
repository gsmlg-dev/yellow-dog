defmodule YellowDog.Store.Backend.Ets do
  @moduledoc """
  ETS-backed storage backend for single-node deployments.

  The ETS table is owned by `YellowDog.Store.ModeDetector`, which creates
  it in `init/1`. This module never creates the table — it trusts the
  lifecycle managed by `ModeDetector`.

  TTL expiration uses both lazy eviction (on read) and a periodic sweep
  (from `ModeDetector`) to reclaim memory for write-heavy keys that are
  never read.
  """

  @behaviour YellowDog.Store.Backend

  @table :yellow_dog_store_ets

  # --- Backend Behaviour ---

  @impl true
  @spec put(String.t(), term(), keyword()) :: :ok
  def put(key, value, opts \\ []) do
    expires_at = compute_expires_at(opts)
    :ets.insert(@table, {key, value, expires_at})
    :ok
  end

  @impl true
  @spec get(String.t(), keyword()) :: {:ok, term()} | {:error, :not_found}
  def get(key, _opts \\ []) do
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

  @impl true
  @spec delete(String.t()) :: :ok
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @impl true
  @spec put_if(String.t(), term(), keyword()) :: :ok | {:error, :condition_failed}
  def put_if(key, value, opts \\ []) do
    case Keyword.get(opts, :condition) do
      nil ->
        expected = Keyword.get(opts, :expected)
        current = raw_get(key)

        if current == expected do
          expires_at = compute_expires_at(opts)
          :ets.insert(@table, {key, value, expires_at})
          :ok
        else
          {:error, :condition_failed}
        end

      condition_fn when is_function(condition_fn, 1) ->
        current = raw_get(key)

        case condition_fn.(current) do
          true ->
            expires_at = compute_expires_at(opts)
            :ets.insert(@table, {key, value, expires_at})
            :ok

          {:update, new_value} ->
            expires_at = compute_expires_at(opts)
            :ets.insert(@table, {key, new_value, expires_at})
            :ok

          {:update, new_value, ttl_opts} ->
            expires_at = compute_expires_at(Keyword.merge(opts, ttl_opts))
            :ets.insert(@table, {key, new_value, expires_at})
            :ok

          false ->
            {:error, :condition_failed}
        end
    end
  end

  @impl true
  @spec prefix_scan(String.t(), keyword()) :: {:ok, [{String.t(), term()}]}
  def prefix_scan(prefix, opts \\ []) do
    limit = Keyword.get(opts, :limit)
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

    sorted = Enum.sort_by(results, fn {key, _} -> key end)

    {:ok, if(limit, do: Enum.take(sorted, limit), else: sorted)}
  end

  @impl true
  @spec put_many(list()) :: {:ok, map()}
  def put_many(operations) do
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

  # --- Table Management (called by ModeDetector) ---

  @doc "Creates the ETS table. Called once by ModeDetector.init/1."
  @spec create_table() :: :ok
  def create_table do
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

  @doc "Sweeps expired entries from the ETS table. Called periodically by ModeDetector."
  @spec sweep_expired() :: integer()
  def sweep_expired do
    case :ets.whereis(@table) do
      :undefined ->
        0

      _ref ->
        now = System.system_time(:second)

        expired_keys =
          :ets.foldl(
            fn {key, _value, expires_at}, acc ->
              if expired?(expires_at, now), do: [key | acc], else: acc
            end,
            [],
            @table
          )

        Enum.each(expired_keys, &:ets.delete(@table, &1))
        length(expired_keys)
    end
  end

  @doc "Returns the ETS table name (for testing)."
  @spec table() :: atom()
  def table, do: @table

  # --- Private ---

  defp compute_expires_at(opts) do
    case Keyword.get(opts, :ttl) do
      nil -> nil
      ttl -> System.system_time(:second) + ttl
    end
  end

  defp raw_get(key) do
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
