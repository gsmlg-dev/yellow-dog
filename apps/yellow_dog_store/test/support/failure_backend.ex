defmodule YellowDog.Store.Test.FailureBackend do
  @moduledoc false

  @behaviour YellowDog.Store.Backend

  alias YellowDog.Store.Backend.Ets

  @state __MODULE__.State

  def configure(actions) when is_list(actions) do
    ensure_started()
    Agent.update(@state, fn _state -> %{actions: actions, calls: []} end)
  end

  def reset, do: configure([])

  def calls do
    ensure_started()
    Agent.get(@state, &Enum.reverse(&1.calls))
  end

  def writes do
    Enum.filter(calls(), fn
      {:put, _, _} -> true
      {:put_if, _, _} -> true
      {:put_many, _} -> true
      {:delete, _} -> true
      {:txn, _} -> true
      _ -> false
    end)
  end

  @impl true
  def put(key, value, opts \\ []) do
    record_call({:put, key, opts})
    Ets.put(key, value, opts)
  end

  @impl true
  def get(key, opts \\ []) do
    record_call({:get, key, opts})

    case take_action(:get, key) do
      :pass -> Ets.get(key, opts)
      {:error, reason} -> {:error, reason}
      nil -> Ets.get(key, opts)
    end
  end

  @impl true
  def delete(key) do
    record_call({:delete, key})

    case take_action(:delete, key) do
      {:error, reason} ->
        {:error, reason}

      {:delete_then_exit, reason} ->
        :ok = Ets.delete(key)
        exit(reason)

      nil ->
        Ets.delete(key)
    end
  end

  @impl true
  def put_if(key, value, opts \\ []) do
    record_call({:put_if, key, opts})

    case take_action(:put_if, key) do
      :pass ->
        Ets.put_if(key, value, opts)

      {:error, reason} ->
        {:error, reason}

      {:write_then_error, reason} ->
        :ok = Ets.put_if(key, value, opts)
        {:error, reason}

      {:exit, reason} ->
        exit(reason)

      {:write_then_exit, reason} ->
        :ok = Ets.put_if(key, value, opts)
        exit(reason)

      nil ->
        Ets.put_if(key, value, opts)
    end
  end

  @impl true
  def prefix_scan(prefix, opts \\ []) do
    record_call({:prefix_scan, prefix, opts})

    case take_action(:prefix_scan, prefix) do
      {:error, reason} ->
        {:error, reason}

      {:delegate_then_set_active, backend} ->
        result = Ets.prefix_scan(prefix, opts)
        YellowDog.Store.Backend.set_active(backend)
        result

      nil ->
        Ets.prefix_scan(prefix, opts)
    end
  end

  @impl true
  def put_many(operations) do
    record_call({:put_many, Enum.map(operations, &elem(&1, 0))})

    case take_action(:put_many, nil) do
      :pass ->
        Ets.put_many(operations)

      {:partial, count, outcome} ->
        write_partial(operations, count)
        resolve_outcome(outcome)

      {:delegate_then, outcome} ->
        {:ok, _results} = Ets.put_many(operations)
        resolve_outcome(outcome)

      {:barrier, count, notify, ref, outcome} ->
        write_partial(operations, count)
        send(notify, {:backend_barrier, ref, self()})

        receive do
          {:release_backend, ^ref} -> resolve_outcome(outcome)
        after
          5_000 -> exit(:barrier_timeout)
        end

      nil ->
        Ets.put_many(operations)
    end
  end

  @impl true
  def txn(spec, opts \\ []) do
    record_call({:txn, spec})

    case take_action(:txn, classify_txn(spec)) do
      :pass ->
        Ets.txn(spec, opts)

      {:delegate_then, outcome} ->
        {:ok, _result} = Ets.txn(spec, opts)
        resolve_outcome(outcome)

      {:delegate_then_tamper_header, updates, outcome} ->
        {:ok, _result} = Ets.txn(spec, opts)
        tamper_header(spec, updates)
        resolve_outcome(outcome)

      {:delegate_then_tamper_key, key, value} ->
        {:ok, _result} = result = Ets.txn(spec, opts)
        :ok = Ets.put(key, value)
        result

      {:exit, reason} ->
        exit(reason)

      {:delegate_then_exit, reason} ->
        {:ok, _result} = Ets.txn(spec, opts)
        exit(reason)

      {:error, reason} ->
        {:error, reason}

      {:barrier_before, notify, ref, outcome} ->
        send(notify, {:backend_barrier, ref, self()})

        receive do
          {:release_backend, ^ref} -> resolve_txn_outcome(spec, opts, outcome)
        after
          5_000 -> exit(:barrier_timeout)
        end

      {:barrier_after, notify, ref, outcome} ->
        {:ok, _result} = result = Ets.txn(spec, opts)
        send(notify, {:backend_barrier, ref, self()})

        receive do
          {:release_backend, ^ref} ->
            if outcome == :pass, do: result, else: resolve_outcome(outcome)
        after
          5_000 -> exit(:barrier_timeout)
        end

      nil ->
        Ets.txn(spec, opts)
    end
  end

  @impl true
  def recovery_durability, do: Ets.recovery_durability()

  defp ensure_started do
    case Process.whereis(@state) do
      nil ->
        case Agent.start(fn -> %{actions: [], calls: []} end, name: @state) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp record_call(call) do
    ensure_started()
    Agent.update(@state, &%{&1 | calls: [call | &1.calls]})
  end

  defp take_action(operation, key) do
    ensure_started()

    Agent.get_and_update(@state, fn state ->
      case state.actions do
        [action | rest] ->
          if matches_action?(action, operation, key) do
            {action_outcome(action), %{state | actions: rest}}
          else
            {nil, state}
          end

        [] ->
          {nil, state}
      end
    end)
  end

  defp matches_action?({:put_many, _outcome}, :put_many, _key), do: true
  defp matches_action?({:txn, _outcome}, :txn, _key), do: true
  defp matches_action?({:txn, classifier, _outcome}, :txn, classifier), do: true

  defp matches_action?({:get_prefix, prefix, _outcome}, :get, key),
    do: String.starts_with?(key, prefix)

  defp matches_action?({:put_if_prefix, prefix, _outcome}, :put_if, key),
    do: String.starts_with?(key, prefix)

  defp matches_action?({:delete_prefix, prefix, _outcome}, :delete, key),
    do: String.starts_with?(key, prefix)

  defp matches_action?({operation, key, _outcome}, operation, key), do: true
  defp matches_action?(_action, _operation, _key), do: false

  defp action_outcome({:put_many, outcome}), do: outcome
  defp action_outcome({:txn, outcome}), do: outcome
  defp action_outcome({:txn, _classifier, outcome}), do: outcome
  defp action_outcome({:get_prefix, _prefix, outcome}), do: outcome
  defp action_outcome({:put_if_prefix, _prefix, outcome}), do: outcome
  defp action_outcome({:delete_prefix, _prefix, outcome}), do: outcome
  defp action_outcome({_operation, _key, outcome}), do: outcome

  defp classify_txn(%{success: operations}) do
    header_values =
      for {:put, key, value, _opts} <- operations,
          String.starts_with?(key, YellowDog.Store.Key.zone_replacement_header_prefix()),
          do: value

    data_count =
      Enum.count(operations, fn
        {:put, key, _value, _opts} ->
          String.starts_with?(key, "dns:view:") and String.contains?(key, ":rr:")

        {:delete, {:key, key}, _opts} ->
          String.starts_with?(key, "dns:view:") and String.contains?(key, ":rr:")

        _other ->
          false
      end)

    case {header_values, data_count, operations} do
      {[%{phase: :preparing}], 0, _} ->
        :intent

      {[%{phase: :applying}], 0, _} ->
        :begin_applying

      {[%{phase: phase, next_chunk: cursor}], count, _} when count > 0 ->
        {:apply, cursor, phase}

      {[%{phase: :events}], 0, [_zone_put, _header_put]} ->
        :finalize

      {[%{phase: phase, event_state: %{cursor: cursor}}], 0, _}
      when phase in [:events, :cleanup] ->
        {:event, cursor, phase}

      {[], 0, [{:delete, {:key, key}, _opts}]} ->
        if String.starts_with?(key, YellowDog.Store.Key.zone_replacement_header_prefix()),
          do: :header_cleanup,
          else: :other

      _other ->
        :other
    end
  end

  defp resolve_txn_outcome(spec, opts, :pass), do: Ets.txn(spec, opts)
  defp resolve_txn_outcome(_spec, _opts, outcome), do: resolve_outcome(outcome)

  defp tamper_header(%{success: operations}, updates) do
    case Enum.find(operations, fn
           {:put, key, value, _opts} ->
             String.starts_with?(key, YellowDog.Store.Key.zone_replacement_header_prefix()) and
               is_map(value)

           _operation ->
             false
         end) do
      {:put, key, value, _opts} -> Ets.put(key, Map.merge(value, updates))
      nil -> :ok
    end
  end

  defp write_partial(_operations, 0), do: :ok

  defp write_partial(operations, count) do
    {:ok, _results} = operations |> Enum.take(count) |> Ets.put_many()
    :ok
  end

  defp resolve_outcome({:ok, results}), do: {:ok, results}
  defp resolve_outcome({:error, reason}), do: {:error, reason}
end
