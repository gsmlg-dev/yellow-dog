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
        expires_at = compute_expires_at(opts)

        if expected == nil do
          atomic_insert_new(key, value, expires_at)
        else
          atomic_cas(key, expected, value, expires_at)
        end

      condition_fn when is_function(condition_fn, 1) ->
        current = raw_get(key)

        case condition_fn.(current) do
          false ->
            {:error, :condition_failed}

          result ->
            {final_value, final_expires} =
              case result do
                true -> {value, compute_expires_at(opts)}
                {:update, nv} -> {nv, compute_expires_at(opts)}
                {:update, nv, ttl_opts} -> {nv, compute_expires_at(Keyword.merge(opts, ttl_opts))}
              end

            if current == nil do
              atomic_insert_new(key, final_value, final_expires)
            else
              atomic_cas(key, current, final_value, final_expires)
            end
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

  @impl true
  @spec txn(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def txn(spec, _opts \\ []) do
    lock_id = {{__MODULE__, :txn}, self()}

    case :global.trans(lock_id, fn -> execute_txn(spec) end) do
      :aborted -> {:error, :aborted}
      {:aborted, reason} -> {:error, reason}
      result -> result
    end
  end

  @impl true
  def recovery_durability, do: :caller_process_while_table_survives

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

  defp execute_txn(spec) do
    with :ok <- validate_txn(spec) do
      succeeded = Enum.all?(spec.compare, &compare_matches?/1)
      branch = if succeeded, do: spec.success, else: Map.get(spec, :failure, [])
      :ok = execute_operations(branch)
      {:ok, %{succeeded: succeeded, revision: 0, responses: []}}
    end
  end

  defp validate_txn(%{compare: compares, success: success} = spec)
       when is_list(compares) and is_list(success) do
    failure = Map.get(spec, :failure, [])

    if is_list(failure) do
      normalized = Map.put(spec, :failure, failure)

      with :ok <- validate_compares(compares),
           :ok <- validate_operations(success),
           :ok <- validate_operations(failure),
           :ok <- Concord.Validation.validate_txn_spec(normalized) do
        :ok
      end
    else
      {:error, {:invalid_txn, :invalid_spec}}
    end
  end

  defp validate_txn(_spec), do: {:error, {:invalid_txn, :invalid_spec}}

  defp validate_compares(compares) do
    Enum.reduce_while(compares, :ok, fn compare, :ok ->
      case validate_compare(compare) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_compare({:exists, key, :==, expected})
       when is_binary(key) and is_boolean(expected),
       do: validate_key(key)

  defp validate_compare({:value, key, :==, _expected}) when is_binary(key),
    do: validate_key(key)

  defp validate_compare(_compare), do: {:error, {:invalid_txn, :unsupported_compare}}

  defp validate_operations(operations) do
    Enum.reduce_while(operations, :ok, fn operation, :ok ->
      case validate_operation(operation) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_operation({:put, key, _value, opts}) when is_binary(key) and is_map(opts),
    do: validate_key(key)

  defp validate_operation({:delete, {:key, key}, opts}) when is_binary(key) and is_map(opts),
    do: validate_key(key)

  defp validate_operation(_operation), do: {:error, {:invalid_txn, :unsupported_op}}

  defp validate_key(""), do: {:error, {:invalid_txn, :empty_key}}

  defp validate_key(key) when byte_size(key) > 1_024,
    do: {:error, {:invalid_txn, :key_too_large}}

  defp validate_key(_key), do: :ok

  defp compare_matches?({:exists, key, :==, expected}) when is_boolean(expected) do
    present? = match?({:ok, _value}, get(key))
    present? == expected
  end

  defp compare_matches?({:value, key, :==, expected}) do
    case get(key) do
      {:ok, value} -> value == expected
      {:error, :not_found} -> expected == nil
    end
  end

  defp execute_operations(operations) do
    Enum.each(operations, &execute_operation/1)
    :ok
  end

  defp execute_operation({:put, key, value, opts}) when is_map(opts) do
    put(key, value, Map.to_list(opts))
  end

  defp execute_operation({:delete, {:key, key}, _opts}), do: delete(key)
  # Atomic insert — only succeeds if key doesn't exist (or is expired).
  defp atomic_insert_new(key, value, expires_at) do
    if :ets.insert_new(@table, {key, value, expires_at}) do
      :ok
    else
      # Key exists in ETS — check if expired and retry once
      case :ets.lookup(@table, key) do
        [{^key, _v, exp}] when not is_nil(exp) ->
          if System.system_time(:second) >= exp do
            :ets.delete(@table, key)

            if :ets.insert_new(@table, {key, value, expires_at}),
              do: :ok,
              else: {:error, :condition_failed}
          else
            {:error, :condition_failed}
          end

        _ ->
          {:error, :condition_failed}
      end
    end
  end

  # CAS: atomic compare-and-swap using :ets.select_replace/2.
  # This is a single atomic operation — no race window between read and write.
  defp atomic_cas(key, expected, new_value, expires_at) do
    # Match spec: match the row where key and value equal expected,
    # then replace with the new value. Returns count of replaced rows.
    match_spec = [
      {
        {key, :"$1", :"$2"},
        [{:==, :"$1", {:const, expected}}],
        [{{key, {:const, new_value}, {:const, expires_at}}}]
      }
    ]

    case :ets.select_replace(@table, match_spec) do
      1 -> :ok
      0 -> {:error, :condition_failed}
    end
  end

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
