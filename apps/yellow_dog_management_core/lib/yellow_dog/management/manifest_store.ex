defmodule YellowDog.Management.ManifestStore do
  @moduledoc false

  use GenServer

  require Logger

  alias YellowDog.Management.Event
  alias YellowDog.Management.EventStore
  alias YellowDog.Management.EventStore.Config
  alias YellowDog.Management.EventStore.Reservation
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Sync.Error

  @outbox_key "registration_audit_outbox"
  @max_registration_bytes 32_768
  @outbox_keys Enum.sort([
                 "event",
                 "event_digest",
                 "previous_registration",
                 "registration_digest",
                 "schema_version"
               ])

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc false
  def update_section(path, section, updater)
      when is_binary(path) and is_binary(section) and section != "" and
             is_function(updater, 1) do
    {deadline, config} = EventStore.operation()

    bounded_call(
      {:update_section, path, section, updater, deadline, config},
      deadline,
      3,
      config
    )
  end

  @doc false
  def commit_section(path, section, commit)
      when is_binary(path) and is_binary(section) and section != "" and
             is_function(commit, 1) do
    {deadline, config} = EventStore.operation()

    commit_section(path, section, commit, deadline, config)
  end

  @doc false
  def commit_section(path, section, commit, deadline, %Config{} = config)
      when is_binary(path) and is_binary(section) and section != "" and
             is_function(commit, 1) and is_integer(deadline) do
    bounded_call(
      {:commit_section, path, section, commit, deadline, config},
      deadline,
      3,
      config
    )
  end

  @doc false
  def update_section_with(path, section, updater, after_write)
      when is_binary(path) and is_binary(section) and section != "" and
             is_function(updater, 1) and is_function(after_write, 0) do
    {deadline, config} = EventStore.operation()
    update_section_with(path, section, updater, after_write, deadline, config)
  end

  @doc false
  def update_section_with(path, section, updater, after_write, deadline)
      when is_integer(deadline) do
    update_section_with(path, section, updater, after_write, deadline, EventStore.config())
  end

  @doc false
  def commit_registration(path, registration, %Reservation{} = reservation, deadline)
      when is_binary(path) and is_map(registration) and is_integer(deadline) do
    request = {:commit_registration, path, registration, reservation, deadline}

    GenServer.call(
      __MODULE__,
      request,
      EventStore.call_timeout(deadline, 2, reservation.config)
    )
  catch
    :exit, {:timeout, _reason} ->
      reconcile_commit_result(path, registration, reservation, EventStore.timeout_result())

    :exit, _reason ->
      reconcile_commit_result(path, registration, reservation, internal_error())
  end

  @doc false
  def persist_event(%Reservation{} = reservation, deadline) when is_integer(deadline) do
    GenServer.call(
      __MODULE__,
      {:persist_event, reservation, deadline},
      EventStore.call_timeout(deadline, 2, reservation.config)
    )
  catch
    :exit, {:timeout, _reason} -> reconcile_event_result(reservation, EventStore.timeout_result())
    :exit, _reason -> reconcile_event_result(reservation, internal_error())
  end

  @doc false
  def reconcile_registration(path) when is_binary(path) do
    {deadline, config} = EventStore.operation()

    bounded_call(
      {:reconcile_registration, path, deadline, config},
      deadline,
      2,
      config
    )
  end

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    cleanup_stale_staging_files(EventStore.config())
    {:ok, nil}
  end

  @impl true
  def handle_call(
        {:update_section, path, section, updater, deadline, config},
        _from,
        state
      ) do
    {:reply, update_section_commit(path, section, updater, deadline, config), state}
  end

  def handle_call(
        {:commit_section, path, section, commit, deadline, config},
        _from,
        state
      ) do
    {:reply, commit_section_commit(path, section, commit, deadline, config), state}
  end

  def handle_call(
        {:update_section_with, path, section, updater, after_write, deadline, config},
        _from,
        state
      ) do
    result = update_section_with_commit(path, section, updater, after_write, deadline, config)
    {:reply, result, state}
  end

  def handle_call(
        {:commit_registration, path, registration, reservation, deadline},
        _from,
        state
      ) do
    result = do_commit_registration(path, registration, reservation, deadline)
    {:reply, result, state}
  end

  def handle_call({:persist_event, reservation, deadline}, _from, state) do
    {:reply, commit_event(reservation, deadline), state}
  end

  def handle_call({:reconcile_registration, path, deadline, config}, _from, state) do
    {:reply, reconcile_manifest(path, deadline, config), state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:event_stage_result, _token, _result}, state), do: {:noreply, state}
  def handle_info({:event_promote_result, _token, _result}, state), do: {:noreply, state}
  def handle_info({:manifest_write_result, _token, _result}, state), do: {:noreply, state}

  def handle_info({:manifest_file_operation_result, _token, _result}, state),
    do: {:noreply, state}

  defp update_section_with(path, section, updater, after_write, deadline, %Config{} = config) do
    bounded_call(
      {:update_section_with, path, section, updater, after_write, deadline, config},
      deadline,
      2,
      config
    )
  end

  defp do_commit_registration(path, registration, reservation, deadline) do
    config = reservation.config

    with :ok <- ensure_before_deadline(deadline),
         :ok <- validate_registration(registration),
         {:ok, manifest} <- reconcile_manifest(path, deadline, config),
         {:ok, previous_registration} <- previous_registration(manifest),
         outbox = build_outbox(registration, previous_registration, reservation),
         desired_manifest =
           manifest
           |> Map.put("registration", registration)
           |> Map.put(@outbox_key, outbox),
         :ok <- write_registration_outbox(path, desired_manifest, outbox, deadline, config) do
      test_hook(config, :after_outbox_write, %{path: path, reservation: reservation})

      result =
        if deadline_expired?(deadline) do
          EventStore.timeout_result()
        else
          commit_event(reservation, deadline)
        end

      finish_registration_commit(path, registration, outbox, reservation, deadline, result)
    end
  end

  defp finish_registration_commit(
         path,
         registration,
         outbox,
         reservation,
         deadline,
         {:ok, event}
       ) do
    case clear_outbox(path, registration, outbox, reservation, deadline) do
      :ok ->
        test_hook(reservation.config, :after_outbox_clear, %{
          path: path,
          reservation: reservation
        })

        {:ok, event}

      {:error, _reason} ->
        reconcile_commit_result(path, registration, reservation, internal_error())
    end
  end

  defp finish_registration_commit(
         path,
         _registration,
         outbox,
         reservation,
         deadline,
         {:error, _reason} = error
       ) do
    case rollback_outbox(path, outbox, deadline, reservation.config) do
      :ok -> error
      {:error, _reason} = rollback_error -> rollback_error
    end
  end

  defp commit_event(reservation, deadline) do
    cond do
      exact_final?(reservation) ->
        {:ok, reservation.event}

      deadline_expired?(deadline) ->
        EventStore.timeout_result()

      true ->
        case stage_event(reservation, deadline) do
          :ok -> promote_and_reconcile(reservation, deadline)
          {:error, _reason} = error -> error
        end
    end
  end

  defp stage_event(reservation, deadline) do
    owner = self()
    token = make_ref()

    {worker_pid, monitor_ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            AtomicJson.stage(
              reservation.final_path,
              reservation.event_map,
              reservation.staging_path,
              reservation.config.file_ops
            )

          send(owner, {:event_stage_result, token, result})
        end,
        [:link, :monitor]
      )

    await_event_stage(worker_pid, monitor_ref, token, reservation, deadline)
  end

  defp await_event_stage(worker_pid, monitor_ref, token, reservation, deadline) do
    receive do
      {:event_stage_result, ^token, {:ok, staging_path}}
      when staging_path == reservation.staging_path ->
        await_worker_down(worker_pid, monitor_ref, token)

        if deadline_expired?(deadline) do
          cleanup_staging(reservation)
          EventStore.timeout_result()
        else
          :ok
        end

      {:event_stage_result, ^token, {:error, %Error{}} = error} ->
        await_worker_down(worker_pid, monitor_ref, token)
        error

      {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} ->
        flush_worker_messages(worker_pid, token)
        cleanup_staging(reservation)
        internal_error()

      {:EXIT, ^worker_pid, _reason} ->
        await_worker_down(worker_pid, monitor_ref, token)
        cleanup_staging(reservation)
        internal_error()
    after
      max(deadline - monotonic_ms(), 0) ->
        Process.exit(worker_pid, :kill)
        await_worker_down(worker_pid, monitor_ref, token)
        cleanup_staging(reservation)
        EventStore.timeout_result()
    end
  end

  defp await_worker_down(worker_pid, monitor_ref, token) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} ->
        flush_worker_messages(worker_pid, token)

      {:event_stage_result, ^token, _result} ->
        await_worker_down(worker_pid, monitor_ref, token)

      {:EXIT, ^worker_pid, _reason} ->
        await_worker_down(worker_pid, monitor_ref, token)
    end
  end

  defp flush_worker_messages(worker_pid, token) do
    receive do
      {:EXIT, ^worker_pid, _reason} -> flush_worker_messages(worker_pid, token)
      {:event_stage_result, ^token, _result} -> flush_worker_messages(worker_pid, token)
    after
      0 -> :ok
    end
  end

  defp promote_and_reconcile(reservation, deadline) do
    if deadline_expired?(deadline) do
      cleanup_staging(reservation)
      EventStore.timeout_result()
    else
      owner = self()
      token = make_ref()

      {worker_pid, monitor_ref} =
        :erlang.spawn_opt(
          fn ->
            result = run_event_promotion(reservation, deadline)
            send(owner, {:event_promote_result, token, result})
          end,
          [:link, :monitor]
        )

      await_event_promotion(worker_pid, monitor_ref, token, reservation, deadline)
    end
  end

  defp run_event_promotion(reservation, deadline) do
    with :ok <- ensure_before_deadline(deadline) do
      test_hook(reservation.config, :before_event_promote, %{reservation: reservation})

      with :ok <- ensure_before_deadline(deadline) do
        AtomicJson.promote(
          reservation.staging_path,
          reservation.final_path,
          reservation.config.file_ops
        )
      end
    end
  end

  defp await_event_promotion(worker_pid, monitor_ref, token, reservation, deadline) do
    receive do
      {:event_promote_result, ^token, result} ->
        await_promotion_worker_down(worker_pid, monitor_ref, token)
        reconcile_event_promotion(reservation, result)

      {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} ->
        result = take_promotion_result(token, internal_error())
        flush_promotion_worker_messages(worker_pid, token)
        reconcile_event_promotion(reservation, result)

      {:EXIT, ^worker_pid, _reason} ->
        await_promotion_worker_down(worker_pid, monitor_ref, token)
        result = take_promotion_result(token, internal_error())
        reconcile_event_promotion(reservation, result)
    after
      max(deadline - monotonic_ms(), 0) ->
        Process.exit(worker_pid, :kill)
        await_promotion_worker_down(worker_pid, monitor_ref, token)
        reconcile_event_promotion(reservation, EventStore.timeout_result())
    end
  end

  defp await_promotion_worker_down(worker_pid, monitor_ref, token) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} ->
        flush_promotion_worker_messages(worker_pid, token)

      {:event_promote_result, ^token, _result} ->
        await_promotion_worker_down(worker_pid, monitor_ref, token)

      {:EXIT, ^worker_pid, _reason} ->
        await_promotion_worker_down(worker_pid, monitor_ref, token)
    end
  end

  defp take_promotion_result(token, fallback) do
    receive do
      {:event_promote_result, ^token, result} -> result
    after
      0 -> fallback
    end
  end

  defp flush_promotion_worker_messages(worker_pid, token) do
    receive do
      {:EXIT, ^worker_pid, _reason} ->
        flush_promotion_worker_messages(worker_pid, token)

      {:event_promote_result, ^token, _result} ->
        flush_promotion_worker_messages(worker_pid, token)
    after
      0 -> :ok
    end
  end

  defp reconcile_event_promotion(reservation, result) do
    cleanup_staging(reservation)

    if exact_final?(reservation) do
      test_hook(reservation.config, :after_event_promote, %{reservation: reservation})
      {:ok, reservation.event}
    else
      promotion_failure(result)
    end
  end

  defp promotion_failure({:error, %Error{}} = error), do: error
  defp promotion_failure(_result), do: conflict_error()

  defp clear_outbox(path, registration, outbox, reservation, deadline) do
    with :ok <- ensure_before_deadline(deadline),
         true <- exact_final?(reservation),
         {:ok, manifest, _existed?} <- read_manifest(path, deadline, reservation.config),
         true <- manifest["registration"] == registration,
         true <- manifest[@outbox_key] == outbox,
         result <-
           owned_manifest_write(
             path,
             Map.delete(manifest, @outbox_key),
             deadline,
             reservation.config
           ),
         :ok <- accept_committed_manifest_write(result) do
      :ok
    else
      false -> invalid_manifest()
      {:error, _reason} = error -> error
    end
  end

  defp reconcile_manifest(path, deadline, config) do
    with :ok <- ensure_before_deadline(deadline),
         {:ok, manifest, _existed?} <- read_manifest(path, deadline, config) do
      case Map.fetch(manifest, @outbox_key) do
        :error -> {:ok, manifest}
        {:ok, outbox} -> reconcile_outbox(path, manifest, outbox, deadline, config)
      end
    end
  end

  defp reconcile_outbox(path, manifest, outbox, deadline, config) do
    with {:ok, record} <- decode_outbox(outbox, manifest, config),
         :ok <- ensure_before_deadline(deadline) do
      reconciled =
        if exact_record_final?(record, config) do
          Map.delete(manifest, @outbox_key)
        else
          manifest
          |> restore_registration(record.previous_registration)
          |> Map.delete(@outbox_key)
        end

      with result <- owned_manifest_write(path, reconciled, deadline, config),
           :ok <- accept_committed_manifest_write(result) do
        {:ok, reconciled}
      end
    end
  end

  defp decode_outbox(outbox, manifest, config) when is_map(outbox) do
    with true <- Enum.sort(Map.keys(outbox)) == @outbox_keys,
         1 <- outbox["schema_version"],
         event_map when is_map(event_map) <- outbox["event"],
         {:ok, event, commit_token} <- Event.decode_record(event_map),
         event_digest when is_binary(event_digest) <- outbox["event_digest"],
         true <- event_digest == Event.digest(event_map),
         registration when is_map(registration) <- manifest["registration"],
         true <- bounded_registration?(registration),
         true <- outbox["registration_digest"] == Event.digest(registration),
         {:ok, previous_registration} <-
           decode_previous_registration(outbox["previous_registration"]) do
      {:ok,
       %{
         event: event,
         event_map: event_map,
         event_digest: event_digest,
         commit_token: commit_token,
         final_path: event_path(config, event.id),
         previous_registration: previous_registration
       }}
    else
      _invalid -> invalid_manifest()
    end
  end

  defp decode_outbox(_outbox, _manifest, _config), do: invalid_manifest()

  defp decode_previous_registration(%{"present" => false} = value)
       when map_size(value) == 1,
       do: {:ok, :error}

  defp decode_previous_registration(%{"present" => true, "value" => value} = previous)
       when map_size(previous) == 2 and is_map(value) do
    if bounded_registration?(value), do: {:ok, {:ok, value}}, else: invalid_manifest()
  end

  defp decode_previous_registration(_value), do: invalid_manifest()

  defp update_section_commit(path, section, updater, deadline, config) do
    with :ok <- ensure_before_deadline(deadline),
         {:ok, manifest} <- reconcile_manifest(path, deadline, config),
         previous_section = Map.fetch(manifest, section),
         {:ok, updated_section} <- apply_update(updater, Map.get(manifest, section)),
         desired_manifest = Map.put(manifest, section, updated_section),
         :ok <-
           write_manifest_section(
             path,
             section,
             previous_section,
             updated_section,
             desired_manifest,
             deadline,
             config
           ) do
      {:ok, updated_section}
    end
  end

  defp commit_section_commit(path, section, commit, deadline, config) do
    with :ok <- ensure_before_deadline(deadline),
         {:ok, manifest, _existed?} <- read_manifest(path, deadline, config),
         :ok <- reject_pending_registration_audit(manifest),
         previous_section = Map.fetch(manifest, section),
         {:ok, updated_section, result} <- apply_commit(commit, Map.get(manifest, section)),
         desired_manifest = Map.put(manifest, section, updated_section),
         :ok <-
           write_manifest_section(
             path,
             section,
             previous_section,
             updated_section,
             desired_manifest,
             deadline,
             config
           ) do
      {:ok, result}
    end
  end

  defp reject_pending_registration_audit(manifest) do
    if Map.has_key?(manifest, @outbox_key),
      do: pending_registration_audit(),
      else: :ok
  end

  defp update_section_with_commit(path, section, updater, after_write, deadline, config) do
    with :ok <- ensure_before_deadline(deadline),
         {:ok, manifest} <- reconcile_manifest(path, deadline, config),
         previous_section = Map.fetch(manifest, section),
         {:ok, updated_section} <- apply_update(updater, Map.get(manifest, section)),
         desired_manifest = Map.put(manifest, section, updated_section),
         :ok <-
           write_manifest_section(
             path,
             section,
             previous_section,
             updated_section,
             desired_manifest,
             deadline,
             config
           ) do
      result =
        if deadline_expired?(deadline),
          do: EventStore.timeout_result(),
          else: run_after_write(after_write)

      case result do
        :ok ->
          :ok

        {:ok, _value} = success ->
          success

        {:error, _reason} = error ->
          case rollback_section(
                 path,
                 section,
                 previous_section,
                 updated_section,
                 deadline,
                 config
               ) do
            :ok -> error
            {:error, _reason} = rollback_error -> rollback_error
          end
      end
    end
  end

  defp build_outbox(registration, previous_registration, reservation) do
    %{
      "schema_version" => 1,
      "event" => reservation.event_map,
      "event_digest" => reservation.event_digest,
      "registration_digest" => Event.digest(registration),
      "previous_registration" => encode_previous_registration(previous_registration)
    }
  end

  defp previous_registration(manifest) do
    case Map.fetch(manifest, "registration") do
      :error ->
        {:ok, :error}

      {:ok, registration} when is_map(registration) ->
        if bounded_registration?(registration),
          do: {:ok, {:ok, registration}},
          else: invalid_manifest()

      {:ok, _invalid} ->
        invalid_manifest()
    end
  end

  defp encode_previous_registration(:error), do: %{"present" => false}

  defp encode_previous_registration({:ok, registration}),
    do: %{"present" => true, "value" => registration}

  defp reconcile_commit_result(path, registration, reservation, fallback) do
    with true <- exact_final?(reservation),
         {:ok, manifest, _existed?} <- read_manifest_unowned(path, reservation.config),
         true <- manifest["registration"] == registration,
         true <- commit_marker_matches?(manifest, registration, reservation) do
      {:ok, reservation.event}
    else
      _not_committed -> fallback
    end
  end

  defp commit_marker_matches?(manifest, registration, reservation) do
    case Map.fetch(manifest, @outbox_key) do
      :error ->
        true

      {:ok, outbox} ->
        with {:ok, record} <- decode_outbox(outbox, manifest, reservation.config),
             true <- record.event_map == reservation.event_map,
             true <- record.event_digest == reservation.event_digest,
             true <- record.commit_token == reservation.commit_token,
             true <- manifest["registration"] == registration do
          true
        else
          _invalid -> false
        end
    end
  end

  defp reconcile_event_result(reservation, fallback) do
    if exact_final?(reservation), do: {:ok, reservation.event}, else: fallback
  end

  defp exact_final?(reservation) do
    exact_record?(
      reservation.final_path,
      reservation.event_map,
      reservation.event_digest,
      reservation.commit_token,
      reservation.config.file_ops
    )
  end

  defp exact_record_final?(record, config) do
    exact_record?(
      record.final_path,
      record.event_map,
      record.event_digest,
      record.commit_token,
      config.file_ops
    )
  end

  defp exact_record?(path, event_map, event_digest, commit_token, file_ops) do
    with {:ok, value} <- AtomicJson.read(path, file_ops),
         true <- value == event_map,
         true <- Event.digest(value) == event_digest,
         {:ok, _event, ^commit_token} <- Event.decode_record(value) do
      true
    else
      _not_exact -> false
    end
  end

  defp bounded_registration?(registration) do
    case Jason.encode(registration) do
      {:ok, encoded} -> byte_size(encoded) <= @max_registration_bytes
      {:error, _reason} -> false
    end
  end

  defp validate_registration(registration) do
    if bounded_registration?(registration), do: :ok, else: invalid_manifest()
  end

  defp read_manifest(path, deadline, config) do
    case owned_manifest_file_operation(
           fn -> AtomicJson.read(path, config.file_ops) end,
           deadline
         ) do
      {:ok, manifest} when is_map(manifest) -> {:ok, manifest, true}
      {:ok, _invalid} -> invalid_manifest()
      {:error, %Error{code: :not_found}} -> {:ok, %{}, false}
      {:error, %Error{}} = error -> error
    end
  end

  defp read_manifest_unowned(path, config) do
    case AtomicJson.read(path, config.file_ops) do
      {:ok, manifest} when is_map(manifest) -> {:ok, manifest, true}
      {:ok, _invalid} -> invalid_manifest()
      {:error, %Error{code: :not_found}} -> {:ok, %{}, false}
      {:error, %Error{}} = error -> error
    end
  end

  defp apply_update(updater, current_section) do
    case updater.(current_section) do
      updated_section when is_map(updated_section) -> {:ok, updated_section}
      _invalid -> invalid_manifest()
    end
  rescue
    _exception -> invalid_manifest()
  end

  defp apply_commit(commit, current_section) do
    case commit.(current_section) do
      {:ok, updated_section, result} when is_map(updated_section) ->
        {:ok, updated_section, result}

      {:error, %Error{}} = error ->
        error

      _invalid ->
        invalid_manifest()
    end
  rescue
    _exception -> invalid_manifest()
  catch
    _kind, _reason -> internal_error()
  end

  defp run_after_write(after_write) do
    case after_write.() do
      :ok -> :ok
      {:ok, _value} = success -> success
      {:error, %Error{}} = error -> error
      _invalid -> invalid_manifest()
    end
  rescue
    _exception -> internal_error()
  catch
    :exit, {:timeout, _reason} -> EventStore.timeout_result()
    :exit, _reason -> internal_error()
    :throw, _reason -> internal_error()
  end

  defp write_registration_outbox(path, desired_manifest, outbox, deadline, config) do
    case owned_manifest_write(path, desired_manifest, deadline, config) do
      {:ok, _path} ->
        :ok

      {:deadline, _commit_state} ->
        case rollback_outbox(path, outbox, deadline, config) do
          :ok -> EventStore.timeout_result()
          {:error, _reason} = error -> error
        end

      {:cleanup_failed, :committed, cleanup_error} ->
        case rollback_outbox(path, outbox, deadline, config) do
          :ok -> cleanup_error
          {:error, _reason} = error -> error
        end

      {:cleanup_failed, :not_committed, cleanup_error} ->
        cleanup_error

      {:error, _reason} = error ->
        error
    end
  end

  defp write_manifest_section(
         path,
         section,
         previous_section,
         updated_section,
         desired_manifest,
         deadline,
         config
       ) do
    case owned_manifest_write(path, desired_manifest, deadline, config) do
      {:ok, _path} ->
        :ok

      {:deadline, _commit_state} ->
        case rollback_section(
               path,
               section,
               previous_section,
               updated_section,
               deadline,
               config
             ) do
          :ok -> EventStore.timeout_result()
          {:error, _reason} = error -> error
        end

      {:cleanup_failed, :committed, cleanup_error} ->
        case rollback_section(
               path,
               section,
               previous_section,
               updated_section,
               deadline,
               config
             ) do
          :ok -> cleanup_error
          {:error, _reason} = error -> error
        end

      {:cleanup_failed, :not_committed, cleanup_error} ->
        cleanup_error

      {:error, _reason} = error ->
        error
    end
  end

  defp accept_committed_manifest_write({:ok, _path}), do: :ok
  defp accept_committed_manifest_write({:deadline, :committed}), do: :ok

  defp accept_committed_manifest_write({:deadline, :not_committed}),
    do: EventStore.timeout_result()

  defp accept_committed_manifest_write({:error, _reason} = error), do: error

  defp accept_committed_manifest_write({:cleanup_failed, _commit_state, error}), do: error

  defp rollback_outbox(path, outbox, deadline, config) do
    with {:ok, previous_registration} <-
           decode_previous_registration(outbox["previous_registration"]),
         {:ok, manifest, _existed?} <-
           read_manifest(path, recovery_deadline(deadline, config), config) do
      cond do
        outbox_restored?(manifest, previous_registration) ->
          :ok

        manifest[@outbox_key] == outbox ->
          restored =
            manifest
            |> restore_registration(previous_registration)
            |> Map.delete(@outbox_key)

          restore_manifest(
            path,
            restored,
            recovery_deadline(deadline, config),
            config,
            fn verify_deadline ->
              verify_outbox_restored(
                path,
                previous_registration,
                verify_deadline,
                config
              )
            end
          )

        true ->
          internal_error()
      end
    else
      {:error, _reason} = error -> log_rollback_failure(path, error)
    end
  end

  defp rollback_section(
         path,
         section,
         previous_section,
         updated_section,
         _deadline,
         config
       ) do
    rollback_deadline = reserved_deadline(config)

    with {:ok, manifest, _existed?} <- read_manifest(path, rollback_deadline, config) do
      case Map.fetch(manifest, section) do
        ^previous_section ->
          :ok

        {:ok, ^updated_section} ->
          restored = restore_section(manifest, section, previous_section)

          restore_manifest(
            path,
            restored,
            rollback_deadline,
            config,
            fn verify_deadline ->
              verify_section_restored(
                path,
                section,
                previous_section,
                verify_deadline,
                config
              )
            end
          )

        _other ->
          internal_error()
      end
    else
      {:error, _reason} = error -> log_rollback_failure(path, error)
    end
  end

  defp restore_manifest(path, restored, deadline, config, verify) do
    result = owned_manifest_write(path, restored, deadline, config)

    case accept_committed_manifest_write(result) do
      :ok ->
        case verify.(deadline) do
          :ok -> :ok
          {:error, _reason} = error -> unverified_rollback(path, error)
        end

      {:error, _reason} = error ->
        unverified_rollback(path, error)
    end
  end

  defp unverified_rollback(path, error) do
    log_rollback_failure(path, error)
    internal_error()
  end

  defp verify_outbox_restored(path, previous_registration, deadline, config) do
    with {:ok, manifest, _existed?} <- read_manifest(path, deadline, config),
         true <- outbox_restored?(manifest, previous_registration) do
      :ok
    else
      false -> internal_error()
      {:error, _reason} = error -> error
    end
  end

  defp verify_section_restored(path, section, previous_section, deadline, config) do
    with {:ok, manifest, _existed?} <- read_manifest(path, deadline, config),
         true <- Map.fetch(manifest, section) == previous_section do
      :ok
    else
      false -> internal_error()
      {:error, _reason} = error -> error
    end
  end

  defp outbox_restored?(manifest, previous_registration) do
    not Map.has_key?(manifest, @outbox_key) and
      Map.fetch(manifest, "registration") == previous_registration
  end

  defp restore_registration(manifest, {:ok, registration}),
    do: Map.put(manifest, "registration", registration)

  defp restore_registration(manifest, :error), do: Map.delete(manifest, "registration")

  defp restore_section(manifest, section, {:ok, previous}),
    do: Map.put(manifest, section, previous)

  defp restore_section(manifest, section, :error), do: Map.delete(manifest, section)

  defp recovery_deadline(deadline, config), do: deadline + config.transport_margin_ms

  defp owned_manifest_write(path, manifest, deadline, config) do
    owner = self()
    token = make_ref()
    target = manifest_target(manifest)
    staging_path = manifest_staging_path(path, target)

    {worker_pid, monitor_ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            with :ok <- ensure_before_deadline(deadline) do
              perform_manifest_write(path, target, staging_path, config)
            end

          send(owner, {:manifest_write_result, token, result})
        end,
        [:link, :monitor]
      )

    await_manifest_write(
      worker_pid,
      monitor_ref,
      token,
      path,
      target,
      staging_path,
      deadline,
      config
    )
  end

  defp await_manifest_write(
         worker_pid,
         monitor_ref,
         token,
         path,
         target,
         staging_path,
         deadline,
         config
       ) do
    receive do
      {:manifest_write_result, ^token, result} ->
        await_manifest_worker_down(worker_pid, monitor_ref, token)
        finish_manifest_write(path, target, staging_path, result, deadline, config)

      {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} ->
        result = take_manifest_write_result(token, internal_error())
        flush_manifest_worker_messages(worker_pid, token)
        finish_manifest_write(path, target, staging_path, result, deadline, config)

      {:EXIT, ^worker_pid, _reason} ->
        await_manifest_worker_down(worker_pid, monitor_ref, token)
        result = take_manifest_write_result(token, internal_error())
        finish_manifest_write(path, target, staging_path, result, deadline, config)
    after
      max(deadline - monotonic_ms(), 0) ->
        Process.exit(worker_pid, :kill)
        await_manifest_worker_down(worker_pid, monitor_ref, token)

        finish_manifest_write(
          path,
          target,
          staging_path,
          EventStore.timeout_result(),
          deadline,
          config
        )
    end
  end

  defp finish_manifest_write(path, target, staging_path, result, deadline, config) do
    commit_result = reconcile_manifest_write(path, target, result, deadline, config)
    cleanup_result = cleanup_manifest_staging(staging_path, deadline, config)

    case {cleanup_result, commit_result} do
      {:ok, result} -> result
      {{:error, %Error{}} = error, {:ok, _path}} -> {:cleanup_failed, :committed, error}
      {{:error, %Error{}} = error, {:deadline, state}} -> {:cleanup_failed, state, error}
      {{:error, %Error{}} = error, {:error, _reason}} -> error
    end
  end

  defp await_manifest_worker_down(worker_pid, monitor_ref, token) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} ->
        flush_manifest_worker_messages(worker_pid, token)

      {:manifest_write_result, ^token, _result} ->
        await_manifest_worker_down(worker_pid, monitor_ref, token)

      {:EXIT, ^worker_pid, _reason} ->
        await_manifest_worker_down(worker_pid, monitor_ref, token)
    end
  end

  defp take_manifest_write_result(token, fallback) do
    receive do
      {:manifest_write_result, ^token, result} -> result
    after
      0 -> fallback
    end
  end

  defp flush_manifest_worker_messages(worker_pid, token) do
    receive do
      {:EXIT, ^worker_pid, _reason} ->
        flush_manifest_worker_messages(worker_pid, token)

      {:manifest_write_result, ^token, _result} ->
        flush_manifest_worker_messages(worker_pid, token)
    after
      0 -> :ok
    end
  end

  defp reconcile_manifest_write(path, target, result, deadline, config) do
    case manifest_target_matches?(path, target, deadline, config) do
      {:ok, true} ->
        if deadline_expired?(deadline), do: {:deadline, :committed}, else: {:ok, path}

      {:ok, false} ->
        if deadline_expired?(deadline) do
          {:deadline, :not_committed}
        else
          manifest_write_failure(result)
        end

      {:error, %Error{code: :timeout}} ->
        reconcile_manifest_write_after_timeout(path, target, config, deadline)

      {:error, _reason} = error ->
        error
    end
  end

  defp reconcile_manifest_write_after_timeout(path, target, config, _deadline) do
    case manifest_target_matches?(path, target, reserved_deadline(config), config) do
      {:ok, true} -> {:deadline, :committed}
      {:ok, false} -> {:deadline, :not_committed}
      {:error, %Error{code: :timeout}} -> {:deadline, :committed}
      {:error, _reason} = error -> error
    end
  end

  defp manifest_write_failure({:error, %Error{}} = error), do: error
  defp manifest_write_failure(_result), do: internal_error()

  defp perform_manifest_write(path, {:present, manifest}, staging_path, config) do
    AtomicJson.replace(path, manifest, staging_path, config.file_ops)
  end

  defp perform_manifest_write(path, :absent, _staging_path, config) do
    case config.file_ops.rm(path) do
      :ok -> {:ok, path}
      {:error, :enoent} -> {:ok, path}
      {:error, _reason} -> internal_error()
    end
  rescue
    _exception -> internal_error()
  catch
    _kind, _reason -> internal_error()
  end

  defp manifest_staging_path(path, {:present, _manifest}), do: AtomicJson.staging_path(path)
  defp manifest_staging_path(_path, :absent), do: nil

  defp cleanup_manifest_staging(nil, _deadline, _config), do: :ok

  defp cleanup_manifest_staging(staging_path, _deadline, config) do
    cleanup_deadline = reserved_deadline(config)
    first_attempt_deadline = cleanup_attempt_deadline(cleanup_deadline)

    case remove_manifest_staging(staging_path, first_attempt_deadline, config) do
      :ok -> :ok
      {:error, _reason} -> remove_manifest_staging(staging_path, cleanup_deadline, config)
    end
  end

  defp remove_manifest_staging(staging_path, deadline, config) do
    case owned_manifest_file_operation(fn -> config.file_ops.rm(staging_path) end, deadline) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, %Error{}} = error -> error
      {:error, reason} -> manifest_staging_cleanup_error(reason)
      _invalid -> manifest_staging_cleanup_error(:invalid_result)
    end
  end

  defp cleanup_attempt_deadline(cleanup_deadline) do
    now = monotonic_ms()
    min(now + max(div(max(cleanup_deadline - now, 0), 2), 1), cleanup_deadline)
  end

  defp reserved_deadline(config), do: monotonic_ms() + config.transport_margin_ms

  defp manifest_target(manifest) when map_size(manifest) == 0, do: :absent
  defp manifest_target(manifest), do: {:present, manifest}

  defp manifest_target_matches?(path, target, deadline, config) do
    case read_manifest_state(path, deadline, config) do
      {:ok, ^target} -> {:ok, true}
      {:ok, _other} -> {:ok, false}
      {:error, _reason} = error -> error
    end
  end

  defp read_manifest_state(path, deadline, config) do
    case owned_manifest_file_operation(
           fn -> AtomicJson.read(path, config.file_ops) end,
           deadline
         ) do
      {:ok, manifest} when is_map(manifest) -> {:ok, {:present, manifest}}
      {:ok, _invalid} -> invalid_manifest()
      {:error, %Error{code: :not_found}} -> {:ok, :absent}
      {:error, %Error{}} = error -> error
    end
  end

  defp owned_manifest_file_operation(operation, deadline)
       when is_function(operation, 0) and is_integer(deadline) do
    with :ok <- ensure_before_deadline(deadline) do
      owner = self()
      token = make_ref()

      {worker_pid, monitor_ref} =
        :erlang.spawn_opt(
          fn ->
            result = run_manifest_file_operation(operation)
            send(owner, {:manifest_file_operation_result, token, result})
          end,
          [:link, :monitor]
        )

      await_manifest_file_operation(worker_pid, monitor_ref, token, deadline)
    end
  end

  defp run_manifest_file_operation(operation) do
    operation.()
  rescue
    _exception -> internal_error()
  catch
    _kind, _reason -> internal_error()
  end

  defp await_manifest_file_operation(worker_pid, monitor_ref, token, deadline) do
    receive do
      {:manifest_file_operation_result, ^token, result} ->
        await_manifest_file_worker_down(worker_pid, monitor_ref, token)
        result

      {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} ->
        result = take_manifest_file_operation_result(token)
        flush_manifest_file_worker_messages(worker_pid, token)
        result

      {:EXIT, ^worker_pid, _reason} ->
        await_manifest_file_worker_down(worker_pid, monitor_ref, token)
        take_manifest_file_operation_result(token)
    after
      max(deadline - monotonic_ms(), 0) ->
        Process.exit(worker_pid, :kill)
        await_manifest_file_worker_down(worker_pid, monitor_ref, token)
        EventStore.timeout_result()
    end
  end

  defp await_manifest_file_worker_down(worker_pid, monitor_ref, token) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} ->
        flush_manifest_file_worker_messages(worker_pid, token)

      {:manifest_file_operation_result, ^token, _result} ->
        await_manifest_file_worker_down(worker_pid, monitor_ref, token)

      {:EXIT, ^worker_pid, _reason} ->
        await_manifest_file_worker_down(worker_pid, monitor_ref, token)
    end
  end

  defp take_manifest_file_operation_result(token) do
    receive do
      {:manifest_file_operation_result, ^token, result} -> result
    after
      0 -> internal_error()
    end
  end

  defp flush_manifest_file_worker_messages(worker_pid, token) do
    receive do
      {:EXIT, ^worker_pid, _reason} ->
        flush_manifest_file_worker_messages(worker_pid, token)

      {:manifest_file_operation_result, ^token, _result} ->
        flush_manifest_file_worker_messages(worker_pid, token)
    after
      0 -> :ok
    end
  end

  defp cleanup_staging(reservation) do
    reservation.config.file_ops.rm(reservation.staging_path)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp cleanup_stale_staging_files(%Config{root: nil}), do: :ok

  defp cleanup_stale_staging_files(config) do
    directory = Path.join(config.root, "events")

    case File.ls(directory) do
      {:ok, filenames} ->
        Enum.each(filenames, fn filename ->
          if String.starts_with?(filename, ".evt-") and String.ends_with?(filename, ".stage") do
            config.file_ops.rm(Path.join(directory, filename))
          end
        end)

      _missing_or_unreadable ->
        :ok
    end
  rescue
    _exception -> :ok
  end

  defp bounded_call(request, deadline, margin_stages, config) do
    GenServer.call(__MODULE__, request, EventStore.call_timeout(deadline, margin_stages, config))
  catch
    :exit, {:timeout, _reason} -> EventStore.timeout_result()
    :exit, _reason -> internal_error()
  end

  defp ensure_before_deadline(deadline) do
    if deadline_expired?(deadline), do: EventStore.timeout_result(), else: :ok
  end

  defp event_path(%Config{root: root}, event_id) when is_binary(root) do
    Path.join([root, "events", "#{event_id}.json"])
  end

  defp test_hook(%Config{test_hook: hook}, point, context) when is_function(hook, 2),
    do: hook.(point, context)

  defp test_hook(_config, _point, _context), do: :ok

  defp deadline_expired?(deadline), do: deadline <= monotonic_ms()
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp log_rollback_failure(path, error) do
    Logger.error("Failed to roll back manifest section in #{path}: #{inspect(error)}")
    error
  end

  defp conflict_error,
    do: {:error, Error.new(:conflict, "management event final path is occupied", %{})}

  defp pending_registration_audit,
    do: {:error, Error.new(:conflict, "registration audit is pending", %{})}

  defp invalid_manifest,
    do: {:error, Error.new(:invalid, "invalid management manifest", %{})}

  defp internal_error,
    do: {:error, Error.new(:internal, "management manifest commit failed", %{})}

  defp manifest_staging_cleanup_error(reason) do
    {:error,
     Error.new(:internal, "manifest staging cleanup failed", %{"reason" => inspect(reason)})}
  end
end
