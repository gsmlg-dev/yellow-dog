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
    Ets.get(key, opts)
  end

  @impl true
  def delete(key) do
    record_call({:delete, key})

    case take_action(:delete, key) do
      {:error, reason} -> {:error, reason}
      nil -> Ets.delete(key)
    end
  end

  @impl true
  def put_if(key, value, opts \\ []) do
    record_call({:put_if, key, opts})

    case take_action(:put_if, key) do
      {:error, reason} ->
        {:error, reason}

      {:write_then_error, reason} ->
        :ok = Ets.put_if(key, value, opts)
        {:error, reason}

      nil ->
        Ets.put_if(key, value, opts)
    end
  end

  @impl true
  def prefix_scan(prefix, opts \\ []) do
    record_call({:prefix_scan, prefix, opts})

    case take_action(:prefix_scan, prefix) do
      {:error, reason} -> {:error, reason}
      nil -> Ets.prefix_scan(prefix, opts)
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
  defp matches_action?({operation, key, _outcome}, operation, key), do: true
  defp matches_action?(_action, _operation, _key), do: false

  defp action_outcome({:put_many, outcome}), do: outcome
  defp action_outcome({_operation, _key, outcome}), do: outcome

  defp write_partial(_operations, 0), do: :ok

  defp write_partial(operations, count) do
    {:ok, _results} = operations |> Enum.take(count) |> Ets.put_many()
    :ok
  end

  defp resolve_outcome({:ok, results}), do: {:ok, results}
  defp resolve_outcome({:error, reason}), do: {:error, reason}
end
