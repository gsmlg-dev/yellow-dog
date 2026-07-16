defmodule YellowDog.Store.Zone.Replacement do
  @moduledoc false

  alias YellowDog.Store.Key
  alias YellowDog.Store.Zone.Recovery

  @version 1
  @max_data_operations 127
  @max_transaction_bytes 900_000
  @data_byte_budget 800_000

  def max_transaction_bytes, do: @max_transaction_bytes

  def execute(backend, view_name, zone, base_zone, previous, plan) do
    with {:ok, chunks} <- chunk_operations(plan.puts, plan.deletes),
         operation_id = operation_id(),
         header <-
           build_header(operation_id, view_name, zone, base_zone, chunks, plan.changed_count),
         :ok <- create_intent(backend, header),
         :ok <- persist_chunks(backend, header, chunks),
         :ok <- Recovery.recover(backend, view_name, zone),
         :ok <- verify_target(backend, header) do
      {:ok, %{previous: previous, changed_count: plan.changed_count}}
    end
  end

  defp verify_target(backend, header) do
    zone_key = Key.zone(header.view_name, header.zone)
    target_zone = header.target_zone

    case backend.get(zone_key, consistency: :strong) do
      {:ok, ^target_zone} -> {:ok, target_zone}
      {:ok, _other} -> {:error, {:target_verification_failed, :mismatch}}
      {:error, reason} -> {:error, {:target_verification_failed, reason}}
      _invalid_result -> {:error, {:target_verification_failed, :invalid_result}}
    end
    |> case do
      {:ok, _target_zone} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp build_header(operation_id, view_name, zone, base_zone, chunks, changed_count) do
    target_serial =
      next_serial(base_zone.soa.serial, Map.get(base_zone, :serial_strategy, :date_serial))

    target_zone =
      base_zone
      |> Map.put(:soa, Map.put(base_zone.soa, :serial, target_serial))
      |> Map.put(:updated_at, System.system_time(:second))

    %{
      version: @version,
      operation_id: operation_id,
      generation: System.unique_integer([:positive, :monotonic]),
      view_name: view_name,
      zone: zone,
      phase: :preparing,
      base_zone: base_zone,
      target_zone: target_zone,
      target_serial: target_serial,
      plan_count: length(chunks),
      plan_hash: plan_hash(chunks),
      next_chunk: 0,
      changed_count: changed_count,
      event_state: %{cursor: 0, count: changed_count + 1}
    }
  end

  defp create_intent(backend, header) do
    header_key = Key.zone_replacement_header(header.view_name, header.zone)
    zone_key = Key.zone(header.view_name, header.zone)

    spec = %{
      compare: [
        {:value, zone_key, :==, header.base_zone},
        {:exists, header_key, :==, false}
      ],
      success: [{:put, header_key, header, %{}}],
      failure: []
    }

    case backend.txn(spec) do
      {:ok, result} ->
        if txn_succeeded?(result),
          do: :ok,
          else: resolve_intent_creation(backend, header_key, header)

      {:error, _reason} ->
        resolve_intent_creation(backend, header_key, header)
    end
  end

  defp resolve_intent_creation(backend, header_key, header) do
    case backend.get(header_key, consistency: :strong) do
      {:ok, ^header} -> :ok
      {:ok, _other} -> {:error, :replacement_in_progress}
      {:error, :not_found} -> {:error, :zone_changed}
      {:error, reason} -> {:error, {:intent_read_failed, reason}}
    end
  end

  defp persist_chunks(backend, header, chunks) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {chunk, index}, :ok ->
      key = Key.zone_replacement_plan(header.operation_id, index)

      case persist_chunk(backend, key, chunk) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_chunk(backend, key, chunk) do
    case backend.put_if(key, chunk, expected: nil) do
      :ok -> verify_chunk(backend, key, chunk)
      {:error, _reason} -> verify_chunk(backend, key, chunk)
    end
  end

  defp verify_chunk(backend, key, chunk) do
    case backend.get(key, consistency: :strong) do
      {:ok, ^chunk} -> :ok
      {:ok, _other} -> {:error, {:corrupt_plan_chunk, key}}
      {:error, :not_found} -> {:error, {:missing_plan_chunk, key}}
      {:error, reason} -> {:error, {:plan_read_failed, key, reason}}
    end
  end

  defp chunk_operations(puts, deletes) do
    operations =
      Enum.map(puts, fn {key, value} -> {:put, key, value} end) ++
        Enum.map(deletes, fn {key, value} -> {:delete, key, value} end)

    Enum.reduce_while(operations, {:ok, {[], [], 0}}, fn operation,
                                                         {:ok, {chunks, current, size}} ->
      operation_size = :erlang.external_size(to_txn_operation(operation))

      cond do
        operation_size > @data_byte_budget ->
          {:halt, {:error, {:record_too_large, operation_size}}}

        length(current) == @max_data_operations or size + operation_size > @data_byte_budget ->
          {:cont, {:ok, {[Enum.reverse(current) | chunks], [operation], operation_size}}}

        true ->
          {:cont, {:ok, {chunks, [operation | current], size + operation_size}}}
      end
    end)
    |> case do
      {:ok, {chunks, [], _size}} -> {:ok, Enum.reverse(chunks)}
      {:ok, {chunks, current, _size}} -> {:ok, Enum.reverse([Enum.reverse(current) | chunks])}
      {:error, _reason} = error -> error
    end
  end

  def to_txn_operation({:put, key, value}), do: {:put, key, value, %{}}
  def to_txn_operation({:delete, key, _value}), do: {:delete, {:key, key}, %{}}

  def plan_hash(chunks) do
    chunks
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def transaction_within_bound?(spec), do: :erlang.external_size(spec) <= @max_transaction_bytes

  defp txn_succeeded?(%{succeeded: succeeded}), do: succeeded
  defp txn_succeeded?(_result), do: false

  defp operation_id do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp next_serial(current, :date_serial) do
    {{year, month, day}, _} = :calendar.local_time()
    date_base = year * 1_000_000 + month * 10_000 + day * 100
    if current >= date_base, do: current + 1, else: date_base + 1
  end

  defp next_serial(current, :increment), do: current + 1
end
