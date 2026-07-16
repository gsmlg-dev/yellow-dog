defmodule YellowDog.Store.Zone.Recovery do
  @moduledoc false

  alias YellowDog.Store.{EventBridge, Key}
  alias YellowDog.Store.Zone.Replacement

  @version 1
  @unknown_retries 3

  def recover(backend, view_name, zone) do
    recover_with_event_plan(backend, view_name, zone, nil)
  end

  defp recover_with_event_plan(backend, view_name, zone, event_plan) do
    header_key = Key.zone_replacement_header(view_name, zone)

    case backend.get(header_key, consistency: :strong) do
      {:ok, header} -> recover_header(backend, header_key, header, view_name, zone, event_plan)
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:recovery_failed, {:header_read_failed, reason}}}
    end
  end

  defp recover_header(backend, header_key, header, view_name, zone, event_plan) do
    with :ok <- validate_header(header, view_name, zone) do
      case header.phase do
        :preparing -> recover_preparing(backend, header_key, header)
        :applying -> recover_applying(backend, header_key, header)
        :finalizing -> recover_finalizing(backend, header_key, header)
        :events -> recover_events(backend, header_key, header, event_plan)
        :cleanup -> recover_cleanup(backend, header_key, header)
      end
    else
      {:error, reason} -> {:error, {:recovery_failed, reason}}
    end
  end

  defp validate_header(
         %{
           version: @version,
           operation_id: operation_id,
           generation: generation,
           view_name: view_name,
           zone: zone,
           phase: phase,
           base_zone: base_zone,
           target_zone: target_zone,
           target_serial: target_serial,
           plan_count: plan_count,
           plan_hash: plan_hash,
           next_chunk: next_chunk,
           changed_count: changed_count,
           event_state: %{cursor: cursor, count: event_count}
         },
         view_name,
         zone
       )
       when is_binary(operation_id) and is_integer(generation) and
              phase in [:preparing, :applying, :finalizing, :events, :cleanup] and
              is_map(base_zone) and is_map(target_zone) and is_integer(target_serial) and
              is_integer(plan_count) and plan_count > 0 and is_binary(plan_hash) and
              is_integer(next_chunk) and next_chunk >= 0 and next_chunk <= plan_count and
              is_integer(changed_count) and changed_count > 0 and is_integer(cursor) and
              cursor >= 0 and is_integer(event_count) and event_count == changed_count + 1 do
    if get_in(target_zone, [:soa, :serial]) == target_serial and
         valid_progress?(phase, next_chunk, plan_count, cursor, event_count),
       do: :ok,
       else: {:error, :invalid_header}
  end

  defp validate_header(_header, _view_name, _zone), do: {:error, :invalid_header}

  defp recover_preparing(backend, header_key, header) do
    case load_plan(backend, header) do
      {:ok, _chunks} ->
        next_header = %{header | phase: :applying}

        case transition(backend, header_key, header, next_header) do
          :ok -> recover(backend, header.view_name, header.zone)
          {:error, reason} -> {:error, {:recovery_failed, reason}}
        end

      {:error, reason} when reason in [:plan_hash_mismatch] ->
        cleanup_preparing(backend, header_key, header)

      {:error, {kind, _index}}
      when kind in [:missing_plan_chunk, :corrupt_plan_chunk] ->
        cleanup_preparing(backend, header_key, header)

      {:error, reason} ->
        {:error, {:recovery_failed, reason}}
    end
  end

  defp recover_applying(backend, header_key, header) do
    with {:ok, chunks} <- applying_plan(backend, header),
         chunk when is_list(chunk) <- Enum.at(chunks, header.next_chunk),
         next_header <- advance_chunk(header),
         spec <- %{
           compare: [{:value, header_key, :==, header}],
           success:
             Enum.map(chunk, &Replacement.to_txn_operation/1) ++
               [{:put, header_key, next_header, %{}}],
           failure: []
         },
         true <- Replacement.transaction_within_bound?(spec),
         :ok <- transition_spec(backend, header_key, header, next_header, spec, @unknown_retries) do
      recover(backend, header.view_name, header.zone)
    else
      nil -> {:error, {:recovery_failed, :missing_plan_chunk}}
      false -> {:error, {:recovery_failed, :transaction_too_large}}
      {:error, {:recovery_failed, _reason}} = error -> error
      {:error, reason} -> {:error, {:recovery_failed, reason}}
    end
  end

  defp recover_finalizing(backend, header_key, header) do
    zone_key = Key.zone(header.view_name, header.zone)
    next_header = %{header | phase: :events}

    spec = %{
      compare: [
        {:value, header_key, :==, header},
        {:value, zone_key, :==, header.base_zone}
      ],
      success: [
        {:put, zone_key, header.target_zone, %{}},
        {:put, header_key, next_header, %{}}
      ],
      failure: []
    }

    with :ok <- transition_spec(backend, header_key, header, next_header, spec, @unknown_retries) do
      recover(backend, header.view_name, header.zone)
    else
      {:error, reason} -> {:error, {:recovery_failed, reason}}
    end
  end

  defp recover_events(backend, header_key, header, cached_plan) do
    with {:ok, event_plan} <- event_plan(backend, header, cached_plan) do
      cursor = header.event_state.cursor

      if cursor < header.event_state.count do
        with :ok <- deliver_event(backend, header, event_plan.operations, cursor) do
          next_cursor = cursor + 1
          next_phase = if next_cursor == header.event_state.count, do: :cleanup, else: :events

          next_header = %{
            header
            | phase: next_phase,
              event_state: %{header.event_state | cursor: next_cursor}
          }

          with :ok <- transition(backend, header_key, header, next_header) do
            recover_with_event_plan(backend, header.view_name, header.zone, event_plan)
          end
        else
          {:error, reason} -> {:error, {:recovery_failed, reason}}
        end
      else
        {:error, {:recovery_failed, :invalid_event_cursor}}
      end
    else
      {:error, reason} -> {:error, {:recovery_failed, reason}}
    end
  end

  defp recover_cleanup(backend, header_key, header) do
    with :ok <- delete_plan_chunks(backend, header),
         :ok <- delete_header(backend, header_key, header) do
      :ok
    else
      {:error, reason} -> {:error, {:recovery_failed, reason}}
    end
  end

  defp cleanup_preparing(backend, header_key, header) do
    with :ok <- delete_plan_chunks(backend, header),
         :ok <- delete_header(backend, header_key, header) do
      :ok
    else
      {:error, reason} -> {:error, {:recovery_failed, reason}}
    end
  end

  defp applying_plan(backend, header) do
    case load_plan(backend, header) do
      {:ok, chunks} -> {:ok, chunks}
      {:error, reason} -> {:error, {:corrupt_applying_plan, reason}}
    end
  end

  defp event_plan(_backend, header, %{operation_id: operation_id} = cached)
       when operation_id == header.operation_id and cached.plan_hash == header.plan_hash and
              cached.plan_count == header.plan_count and
              cached.changed_count == header.changed_count do
    {:ok, cached}
  end

  defp event_plan(backend, header, _cached) do
    with {:ok, chunks} <- applying_plan(backend, header) do
      operations = chunks |> List.flatten() |> List.to_tuple()

      if tuple_size(operations) == header.changed_count do
        {:ok,
         %{
           operation_id: header.operation_id,
           plan_hash: header.plan_hash,
           plan_count: header.plan_count,
           changed_count: header.changed_count,
           operations: operations
         }}
      else
        {:error, {:corrupt_applying_plan, :operation_count_mismatch}}
      end
    end
  end

  defp load_plan(backend, header) do
    0..(header.plan_count - 1)
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, chunks} ->
      key = Key.zone_replacement_plan(header.operation_id, index)

      case backend.get(key, consistency: :strong) do
        {:ok, chunk} when is_list(chunk) -> {:cont, {:ok, [chunk | chunks]}}
        {:ok, _invalid} -> {:halt, {:error, {:corrupt_plan_chunk, index}}}
        {:error, :not_found} -> {:halt, {:error, {:missing_plan_chunk, index}}}
        {:error, reason} -> {:halt, {:error, {:plan_read_failed, index, reason}}}
      end
    end)
    |> case do
      {:ok, chunks} ->
        chunks = Enum.reverse(chunks)

        if Replacement.plan_hash(chunks) == header.plan_hash,
          do: {:ok, chunks},
          else: {:error, :plan_hash_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  defp advance_chunk(header) do
    next_chunk = header.next_chunk + 1
    phase = if next_chunk == header.plan_count, do: :finalizing, else: :applying
    %{header | next_chunk: next_chunk, phase: phase}
  end

  defp transition(backend, header_key, header, next_header) do
    spec = %{
      compare: [{:value, header_key, :==, header}],
      success: [{:put, header_key, next_header, %{}}],
      failure: []
    }

    transition_spec(backend, header_key, header, next_header, spec, @unknown_retries)
  end

  defp transition_spec(backend, header_key, header, next_header, spec, retries) do
    case backend.txn(spec) do
      {:ok, %{succeeded: true}} ->
        :ok

      {:ok, %{succeeded: false}} ->
        resolve_transition(backend, header_key, header, next_header, spec, retries)

      {:error, _reason} ->
        resolve_transition(backend, header_key, header, next_header, spec, retries)

      _invalid_result ->
        resolve_transition(backend, header_key, header, next_header, spec, retries)
    end
  end

  defp resolve_transition(backend, header_key, header, next_header, spec, retries) do
    case backend.get(header_key, consistency: :strong) do
      {:ok, ^next_header} ->
        :ok

      {:ok, ^header} when retries > 0 ->
        transition_spec(backend, header_key, header, next_header, spec, retries - 1)

      {:ok, ^header} ->
        {:error, :transaction_unknown}

      {:ok, other} ->
        if valid_advanced_header?(header, next_header, other),
          do: :ok,
          else: {:error, :fenced}

      {:error, :not_found} when next_header.phase == :cleanup ->
        :ok

      {:error, :not_found} ->
        {:error, :fenced}

      {:error, reason} ->
        {:error, {:header_read_failed, reason}}
    end
  end

  defp valid_advanced_header?(header, next_header, observed) do
    with :ok <- validate_header(observed, header.view_name, header.zone),
         true <- immutable_header?(header, observed),
         expected_progress when is_tuple(expected_progress) <- progress(next_header),
         observed_progress when is_tuple(observed_progress) <- progress(observed) do
      observed_progress >= expected_progress
    else
      _invalid -> false
    end
  end

  defp immutable_header?(left, right) do
    fields = [
      :version,
      :operation_id,
      :generation,
      :view_name,
      :zone,
      :base_zone,
      :target_zone,
      :target_serial,
      :plan_count,
      :plan_hash,
      :changed_count
    ]

    Map.take(left, fields) == Map.take(right, fields) and
      left.event_state.count == right.event_state.count
  end

  defp valid_progress?(:preparing, 0, _plan_count, 0, _event_count), do: true

  defp valid_progress?(:applying, next_chunk, plan_count, 0, _event_count),
    do: next_chunk < plan_count

  defp valid_progress?(:finalizing, plan_count, plan_count, 0, _event_count), do: true

  defp valid_progress?(:events, plan_count, plan_count, cursor, event_count),
    do: cursor < event_count

  defp valid_progress?(:cleanup, plan_count, plan_count, event_count, event_count), do: true
  defp valid_progress?(_phase, _next_chunk, _plan_count, _cursor, _event_count), do: false

  defp progress(%{phase: :preparing}), do: {0, 0}
  defp progress(%{phase: :applying, next_chunk: next_chunk}), do: {1, next_chunk}
  defp progress(%{phase: :finalizing}), do: {2, 0}
  defp progress(%{phase: :events, event_state: %{cursor: cursor}}), do: {3, cursor}
  defp progress(%{phase: :cleanup}), do: {4, 0}
  defp progress(_header), do: :invalid

  defp delete_plan_chunks(backend, header) do
    0..(header.plan_count - 1)
    |> Enum.reduce_while(:ok, fn index, :ok ->
      case backend.delete(Key.zone_replacement_plan(header.operation_id, index)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:plan_cleanup_failed, index, reason}}}
      end
    end)
  end

  defp delete_header(backend, header_key, header) do
    spec = %{
      compare: [{:value, header_key, :==, header}],
      success: [{:delete, {:key, header_key}, %{}}],
      failure: []
    }

    case backend.txn(spec) do
      {:ok, %{succeeded: true}} ->
        :ok

      _unknown ->
        case backend.get(header_key, consistency: :strong) do
          {:error, :not_found} -> :ok
          {:ok, ^header} -> {:error, :header_cleanup_failed}
          {:ok, _other} -> {:error, :fenced}
          {:error, reason} -> {:error, {:header_read_failed, reason}}
        end
    end
  end

  defp deliver_event(backend, header, _operations, 0) do
    event_key = Key.zone_replacement_header(header.view_name, header.zone)

    with :ok <-
           EventBridge.notify_durable(
             backend,
             header.operation_id,
             0,
             :put,
             event_key,
             %{
               view_name: header.view_name,
               zone: header.zone,
               target_serial: header.target_serial
             },
             delivery: :audit
           ) do
      :telemetry.execute(
        [:yellow_dog, :store, :zone, :serial_incremented],
        %{},
        %{
          zone: header.zone,
          old_serial: header.base_zone.soa.serial,
          new_serial: header.target_serial
        }
      )

      :ok
    end
  end

  defp deliver_event(backend, header, operations, cursor) do
    operation =
      if cursor > 0 and cursor <= tuple_size(operations),
        do: elem(operations, cursor - 1),
        else: nil

    case operation do
      {:put, key, value} ->
        with :ok <-
               EventBridge.notify_durable(
                 backend,
                 header.operation_id,
                 cursor,
                 :put,
                 key,
                 value
               ) do
          emit_operation(header.zone, key, value.owner, value.type, :put)
          :ok
        end

      {:delete, key, value} ->
        with :ok <-
               EventBridge.notify_durable(
                 backend,
                 header.operation_id,
                 cursor,
                 :delete,
                 key,
                 nil
               ) do
          emit_operation(header.zone, key, value.owner, value.type, :delete)
          :ok
        end

      _missing_operation ->
        {:error, :invalid_event_cursor}
    end
  end

  defp emit_operation(zone, key, owner, type, action) do
    :telemetry.execute(
      [:yellow_dog, :store, :operation, :stop],
      %{duration: 0},
      %{namespace: :zone, operation: action, key: key, consistency: :strong}
    )

    :telemetry.execute(
      [:yellow_dog, :store, :zone, :rr_changed],
      %{},
      %{zone: zone, owner: owner, type: type, action: action}
    )
  end
end
