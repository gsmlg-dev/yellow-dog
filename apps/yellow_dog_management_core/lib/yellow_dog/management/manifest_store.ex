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
         :ok <- ensure_before_deadline(deadline),
         {:ok, _path} <-
           AtomicJson.replace(
             path,
             manifest
             |> Map.put("registration", registration)
             |> Map.put(@outbox_key, outbox),
             config.file_ops
           ) do
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
         _deadline,
         {:error, _reason} = error
       ) do
    rollback_outbox(path, outbox, reservation.config)
    error
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
         {:ok, manifest, _existed?} <- read_manifest(path, reservation.config),
         true <- manifest["registration"] == registration,
         true <- manifest[@outbox_key] == outbox,
         :ok <- ensure_before_deadline(deadline),
         {:ok, _path} <-
           AtomicJson.replace(
             path,
             Map.delete(manifest, @outbox_key),
             reservation.config.file_ops
           ) do
      :ok
    else
      false -> invalid_manifest()
      {:error, _reason} = error -> error
    end
  end

  defp reconcile_manifest(path, deadline, config) do
    with :ok <- ensure_before_deadline(deadline),
         {:ok, manifest, _existed?} <- read_manifest(path, config) do
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

      with {:ok, _path} <- replace_or_remove(path, reconciled, config) do
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
         :ok <- ensure_before_deadline(deadline),
         {:ok, _path} <-
           AtomicJson.replace(path, Map.put(manifest, section, updated_section), config.file_ops) do
      if deadline_expired?(deadline) do
        rollback_section(path, section, previous_section, config)
        EventStore.timeout_result()
      else
        {:ok, updated_section}
      end
    end
  end

  defp update_section_with_commit(path, section, updater, after_write, deadline, config) do
    with :ok <- ensure_before_deadline(deadline),
         {:ok, manifest} <- reconcile_manifest(path, deadline, config),
         previous_section = Map.fetch(manifest, section),
         {:ok, updated_section} <- apply_update(updater, Map.get(manifest, section)),
         :ok <- ensure_before_deadline(deadline),
         {:ok, _path} <-
           AtomicJson.replace(path, Map.put(manifest, section, updated_section), config.file_ops) do
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
          rollback_section(path, section, previous_section, config)
          error
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
         {:ok, manifest, _existed?} <- read_manifest(path, reservation.config),
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

  defp read_manifest(path, config) do
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

  defp rollback_outbox(path, outbox, config) do
    with {:ok, manifest, _existed?} <- read_manifest(path, config),
         true <- manifest[@outbox_key] == outbox,
         {:ok, previous_registration} <-
           decode_previous_registration(outbox["previous_registration"]),
         restored <-
           manifest
           |> restore_registration(previous_registration)
           |> Map.delete(@outbox_key),
         {:ok, _path} <- replace_or_remove(path, restored, config) do
      :ok
    else
      false -> :ok
      {:error, _reason} = error -> log_rollback_failure(path, error)
    end
  end

  defp rollback_section(path, section, previous_section, config) do
    with {:ok, manifest, _existed?} <- read_manifest(path, config),
         restored = restore_section(manifest, section, previous_section),
         {:ok, _path} <- replace_or_remove(path, restored, config) do
      :ok
    else
      {:error, _reason} = error -> log_rollback_failure(path, error)
    end
  end

  defp restore_registration(manifest, {:ok, registration}),
    do: Map.put(manifest, "registration", registration)

  defp restore_registration(manifest, :error), do: Map.delete(manifest, "registration")

  defp restore_section(manifest, section, {:ok, previous}),
    do: Map.put(manifest, section, previous)

  defp restore_section(manifest, section, :error), do: Map.delete(manifest, section)

  defp replace_or_remove(path, manifest, config) when map_size(manifest) == 0 do
    case config.file_ops.rm(path) do
      :ok -> {:ok, path}
      {:error, :enoent} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_or_remove(path, manifest, config) do
    AtomicJson.replace(path, manifest, config.file_ops)
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

  defp invalid_manifest,
    do: {:error, Error.new(:invalid, "invalid management manifest", %{})}

  defp internal_error,
    do: {:error, Error.new(:internal, "management manifest commit failed", %{})}
end
