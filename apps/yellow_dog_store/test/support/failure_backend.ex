defmodule YellowDog.Store.Test.FailureBackend do
  @moduledoc false

  @behaviour YellowDog.Store.Backend

  alias YellowDog.Store.Backend.Ets

  @plan_key {__MODULE__, :plan}
  @calls_key {__MODULE__, :calls}

  def configure(actions) when is_list(actions) do
    Process.put(@plan_key, actions)
    Process.put(@calls_key, [])
    :ok
  end

  def reset, do: configure([])

  def calls do
    @calls_key
    |> Process.get([])
    |> Enum.reverse()
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
      {:fail, reason} -> {:error, reason}
      nil -> Ets.delete(key)
    end
  end

  @impl true
  def put_if(key, value, opts \\ []) do
    record_call({:put_if, key, opts})

    case take_action(:put_if, key) do
      {:fail, reason} ->
        {:error, reason}

      {:write_then_fail, reason} ->
        :ok = Ets.put_if(key, value, opts)
        {:error, reason}

      nil ->
        Ets.put_if(key, value, opts)
    end
  end

  @impl true
  def prefix_scan(prefix, opts \\ []) do
    record_call({:prefix_scan, prefix, opts})
    Ets.prefix_scan(prefix, opts)
  end

  @impl true
  def put_many(operations) do
    record_call({:put_many, Enum.map(operations, &elem(&1, 0))})

    case take_action(:put_many, nil) do
      {:partial, count, reason} ->
        {:ok, _} = operations |> Enum.take(count) |> Ets.put_many()
        {:error, reason}

      {:fail, reason} ->
        {:error, reason}

      nil ->
        Ets.put_many(operations)
    end
  end

  defp take_action(operation, key) do
    case Process.get(@plan_key, []) do
      [{^operation, :fail, reason} | rest] when operation == :put_many ->
        Process.put(@plan_key, rest)
        {:fail, reason}

      [{^operation, {:partial, count}, reason} | rest] when operation == :put_many ->
        Process.put(@plan_key, rest)
        {:partial, count, reason}

      [{:delete, ^key, reason} | rest] when operation == :delete ->
        Process.put(@plan_key, rest)
        {:fail, reason}

      [{^operation, ^key, mode, reason} | rest] when operation in [:delete, :put_if] ->
        Process.put(@plan_key, rest)
        {mode, reason}

      _ ->
        nil
    end
  end

  defp record_call(call) do
    Process.put(@calls_key, [call | Process.get(@calls_key, [])])
  end
end
