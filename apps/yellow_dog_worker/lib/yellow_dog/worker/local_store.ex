defmodule YellowDog.Worker.LocalStore do
  @moduledoc """
  Owns a Worker data directory and commits immutable, self-contained TOML plans.

  A Linux flock child holds the directory lock for this process's lifetime. A
  single pointer file names the active and previous snapshots. Snapshots are
  written, synced, and decoded again before the pointer can reference them.
  """

  use GenServer

  alias YellowDog.ConfigSpec
  alias YellowDog.Worker.{FileOps, TransitionJournal}

  @hash ~r/\A[0-9a-f]{64}\z/

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def recover(pid), do: GenServer.call(pid, :recover)
  def prepare(pid, plan), do: GenServer.call(pid, {:prepare, plan}, 30_000)
  def commit(pid, candidate), do: GenServer.call(pid, {:commit, candidate}, 30_000)
  def status(pid), do: GenServer.call(pid, :status)
  def connection_credentials(pid, url), do: GenServer.call(pid, {:connection_credentials, url})

  def begin_transition(pid, candidate, kind, base),
    do: GenServer.call(pid, {:begin_transition, candidate, kind, base}, 30_000)

  def checkpoint(pid, phase), do: GenServer.call(pid, {:checkpoint, phase}, 30_000)

  def dispatch(pid, direction, id, operation),
    do: GenServer.call(pid, {:dispatch, direction, id, operation}, 30_000)

  def observe(pid, result), do: GenServer.call(pid, {:observe, result}, 30_000)
  def reconcile(pid), do: GenServer.call(pid, :reconcile, 30_000)
  def finish(pid, outcome), do: GenServer.call(pid, {:finish, outcome}, 30_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    dir = Keyword.fetch!(opts, :data_dir) |> Path.expand()
    ops = Keyword.get(opts, :file_ops, FileOps)

    with :ok <- reject_symlinks(dir),
         :ok <- File.mkdir_p(dir),
         :ok <- File.mkdir_p(Path.join(dir, "snapshots")),
         :ok <- reject_symlinks(dir),
         :ok <- reject_symlinks(Path.join(dir, "snapshots")),
         :ok <- reject_symlink(Path.join(dir, "current")),
         :ok <- reject_symlinks(Path.join(dir, "journal/transition.toml")),
         :ok <- reject_symlink(Path.join(dir, ".lock")),
         {:ok, lock} <- lock_dir(dir),
         {:ok, pointer} <- read_pointer(dir) do
      {:ok,
       %{
         dir: dir,
         ops: ops,
         lock: lock,
         pointer: pointer,
         prepared: %{},
         error: nil,
         uncertain: nil,
         transition: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:connection_credentials, url}, _from, state) do
    {:reply, YellowDog.Worker.Credentials.resolve(state.dir, url, state.ops), state}
  end

  def handle_call(:recover, _from, %{uncertain: error} = state) when not is_nil(error) do
    # Readable bytes do not establish durability after a failed sync and failed
    # rollback. Only a new successful commit may clear this state.
    {:reply, {:error, error}, state}
  end

  def handle_call(:recover, _from, state) do
    case journal_recovery(state) do
      {:legacy, next} -> recover_legacy(next)
      {reply, next} -> {:reply, reply, next}
    end
  end

  def handle_call(:reconcile, _from, state) do
    case journal_recovery(state) do
      {:legacy, next} ->
        recover_legacy(next)

      {{:ok, plan}, next} ->
        case synchronize_recovery(next) do
          :ok ->
            {:reply, {:ok, plan}, %{next | uncertain: nil}}

          {:error, reason} ->
            {:reply, {:error, reason}, %{next | uncertain: reason, error: reason}}
        end

      {reply, next} ->
        {:reply, reply, next}
    end
  end

  def handle_call({:begin_transition, candidate, kind, base}, _from, state) do
    with {:ok, pointer} <- read_pointer(state.dir),
         :ok <- check_existing_journal(state.dir, pointer, candidate.plan["worker_id"]),
         {:ok, base_hash} <- selected_hash(state.dir, pointer, base),
         {:ok, candidate_plan} <- read_snapshot(state.dir, candidate.hash),
         true <- candidate_plan == candidate.plan do
      record = %{
        "version" => 1,
        "attempt" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        "sequence" => 1,
        "worker_id" => candidate.plan["worker_id"],
        "kind" => kind,
        "base_active" => pointer.active || "none",
        "base_previous" => pointer.previous || "none",
        "base_hash" => base_hash || "none",
        "candidate_hash" => candidate.hash,
        "phase" => "applying",
        "outcome" => "pending",
        "actions" => []
      }

      journal_reply(state, record)
    else
      false -> {:reply, {:error, :candidate_snapshot_mismatch}, state}
      {:error, reason} -> {:reply, {:error, reason}, %{state | error: reason}}
    end
  end

  def handle_call({:checkpoint, phase}, _from, %{transition: record} = state)
      when is_map(record) do
    allowed =
      {record["phase"], phase} in [
        {"applying", "committing"},
        {"applying", "recovering"},
        {"committing", "recovering"}
      ]

    if allowed and (phase == "recovering" or accepted_actions?(record)),
      do: journal_reply(state, advance(record, %{"phase" => phase})),
      else: {:reply, {:error, :invalid_transition_sequence}, state}
  end

  def handle_call({:dispatch, direction, id, operation}, _from, %{transition: record} = state)
      when is_map(record) do
    allowed =
      (direction == "forward" and record["phase"] == "applying" and not dispatched?(record)) or
        (direction == "recovery" and
           (record["phase"] in ["recovering", "pointer_committed"] or
              (record["phase"] == "applying" and record["kind"] == "repair")))

    if allowed do
      action = %{
        "direction" => direction,
        "service" => id,
        "operation" => operation,
        "status" => "dispatched",
        "detail" => ""
      }

      journal_reply(state, advance(record, %{"actions" => record["actions"] ++ [action]}))
    else
      {:reply, {:error, :invalid_transition_sequence}, state}
    end
  end

  def handle_call({:observe, result}, _from, %{transition: record} = state) when is_map(record) do
    if record["phase"] != "complete" and dispatched?(record) do
      actions =
        List.update_at(record["actions"], -1, fn action ->
          Map.merge(action, %{
            "status" => if(result == :ok, do: "accepted", else: "failed"),
            "detail" => if(result == :ok, do: "", else: bounded_detail(result))
          })
        end)

      journal_reply(state, advance(record, %{"actions" => actions}))
    else
      {:reply, {:error, :invalid_transition_sequence}, state}
    end
  end

  def handle_call({:finish, outcome}, _from, %{transition: record} = state) when is_map(record) do
    recovery_accepted =
      record["actions"]
      |> Enum.filter(&(&1["direction"] == "recovery"))
      |> Enum.reverse()
      |> Enum.uniq_by(&{&1["service"], &1["operation"]})
      |> Enum.all?(&(&1["status"] == "accepted"))

    allowed =
      recovery_accepted and
        ((outcome == "committed" and record["phase"] == "pointer_committed") or
           (outcome == "rejected" and record["phase"] == "recovering") or
           (outcome == "repaired" and record["kind"] == "repair" and
              (record["phase"] == "recovering" or
                 (record["phase"] == "applying" and accepted_actions?(record)))))

    if allowed do
      result = if outcome == "rejected", do: restore_base(state), else: :ok

      case result do
        :ok ->
          case read_pointer(state.dir) do
            {:ok, pointer} ->
              journal_reply(
                %{state | pointer: pointer},
                advance(record, %{"phase" => "complete", "outcome" => outcome})
              )

            {:error, reason} ->
              {:reply, {:error, reason}, %{state | error: reason, uncertain: reason}}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, %{state | error: reason, uncertain: reason}}
      end
    else
      {:reply, {:error, :invalid_transition_sequence}, state}
    end
  end

  def handle_call({:checkpoint, _}, _from, state), do: {:reply, {:error, :no_transition}, state}

  def handle_call({:dispatch, _, _, _}, _from, state),
    do: {:reply, {:error, :no_transition}, state}

  def handle_call({:observe, _}, _from, state), do: {:reply, {:error, :no_transition}, state}
  def handle_call({:finish, _}, _from, state), do: {:reply, {:error, :no_transition}, state}

  def handle_call({:prepare, plan}, _from, state) do
    with {:ok, normalized_input} <- ConfigSpec.normalize_plan(plan),
         {:ok, toml} <- ConfigSpec.encode(normalized_input),
         {:ok, normalized} <- ConfigSpec.decode(toml),
         true <- normalized == normalized_input,
         hash <- hash(toml),
         :ok <- install_snapshot(state, hash, toml) do
      candidate = %{hash: hash, plan: normalized}
      {:reply, {:ok, candidate}, %{state | prepared: Map.put(state.prepared, hash, candidate)}}
    else
      false -> {:reply, {:error, :snapshot_roundtrip_mismatch}, state}
      {:error, reason} -> {:reply, {:error, reason}, %{state | error: reason}}
    end
  end

  def handle_call({:commit, %{hash: hash}}, _from, state) do
    record = state.transition

    valid_transition =
      is_nil(record) or
        (record["candidate_hash"] == hash and
           record["phase"] in ["applying", "committing"] and accepted_actions?(record))

    if not valid_transition do
      {:reply, {:error, :invalid_transition_sequence}, state}
    else
      if Map.has_key?(state.prepared, hash) do
        previous_pointer = state.pointer
        new_pointer = %{active: hash, previous: previous_valid_hash(state, hash)}

        intent =
          if state.transition,
            do: persist_journal(state, advance(state.transition, %{"phase" => "committing"})),
            else: {:ok, state}

        case intent do
          {:ok, state} -> commit_pointer(state, hash, previous_pointer, new_pointer)
          {:error, reason, next} -> {:reply, {:error, reason}, next}
        end
      else
        {:reply, {:error, :unknown_candidate}, state}
      end
    end
  end

  def handle_call({:commit, _}, _from, state), do: {:reply, {:error, :unknown_candidate}, state}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       active: state.pointer.active,
       previous: state.pointer.previous,
       prepared: Map.keys(state.prepared),
       transition: state.transition,
       error: state.uncertain || state.error
     }, state}
  end

  @impl true
  def handle_info({:EXIT, lock, reason}, %{lock: lock} = state),
    do: {:stop, {:lock_lost, reason}, state}

  def handle_info({lock, {:exit_status, code}}, %{lock: lock} = state),
    do: {:stop, {:lock_lost, code}, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: Port.close(state.lock)

  defp recover_legacy(state) do
    case read_pointer(state.dir) do
      {:ok, %{active: nil} = pointer} ->
        {:reply, {:ok, nil}, %{state | pointer: pointer, error: nil}}

      {:ok, pointer} ->
        case read_snapshot(state.dir, pointer.active) do
          {:ok, plan} ->
            {:reply, {:ok, plan}, %{state | pointer: pointer, error: nil}}

          {:error, active_error} ->
            case read_snapshot(state.dir, pointer.previous) do
              {:ok, plan} ->
                error = {:recovered_previous, active_error}
                {:reply, {:ok, plan}, %{state | pointer: pointer, error: error}}

              {:error, previous_error} ->
                error = {:unrecoverable, active_error, previous_error}
                {:reply, {:error, error}, %{state | pointer: pointer, error: error}}
            end
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | error: reason}}
    end
  end

  defp commit_pointer(state, hash, previous_pointer, new_pointer) do
    case write_pointer(state, new_pointer) do
      :ok ->
        next = %{
          state
          | pointer: new_pointer,
            prepared: Map.delete(state.prepared, hash),
            error: nil,
            uncertain: nil
        }

        if next.transition do
          with {:ok, committed} <-
                 persist_journal(
                   next,
                   advance(next.transition, %{"phase" => "pointer_committed"})
                 ),
               {:ok, completed} <-
                 persist_journal(
                   committed,
                   advance(committed.transition, %{
                     "phase" => "complete",
                     "outcome" => "committed"
                   })
                 ) do
            {:reply, :ok, completed}
          else
            {:error, reason, failed} -> {:reply, {:error, reason}, failed}
          end
        else
          {:reply, :ok, next}
        end

      {:error, {:post_rename, reason}} ->
        case restore_pointer(state, previous_pointer) do
          :ok ->
            error = {:commit_failed_restored, reason}
            {:reply, {:error, error}, %{state | pointer: previous_pointer, error: error}}

          {:error, restore_reason} ->
            error = {:commit_uncertain, reason, restore_reason}
            {:reply, {:error, error}, %{state | error: error, uncertain: error}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | error: reason}}
    end
  end

  defp lock_dir(dir) do
    executable = System.find_executable("flock")

    if executable do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          args: [
            "-n",
            "-E",
            "73",
            Path.join(dir, ".lock"),
            "sh",
            "-c",
            "printf 'READY\\n'; cat >/dev/null"
          ]
        ])

      receive do
        {^port, {:data, "READY\n"}} -> {:ok, port}
        {^port, {:exit_status, 73}} -> {:error, :directory_locked}
        {^port, {:exit_status, code}} -> {:error, {:lock_failed, code}}
      after
        5_000 ->
          Port.close(port)
          {:error, :lock_timeout}
      end
    else
      {:error, :flock_unavailable}
    end
  end

  defp install_snapshot(state, hash, toml) do
    dir = Path.join(state.dir, "snapshots")
    target = Path.join(dir, hash <> ".toml")

    case bounded_read(target, 1_048_576) do
      {:ok, ^toml} ->
        with :ok <- state.ops.sync_path(target), do: state.ops.sync_path(dir)

      {:ok, _} ->
        replace_snapshot(state, dir, target, toml)

      {:error, :too_large} ->
        replace_snapshot(state, dir, target, toml)

      {:error, :enoent} ->
        replace_snapshot(state, dir, target, toml)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_snapshot(state, dir, target, toml) do
    temp = temp_path(dir)

    with :ok <- reject_symlink(target),
         :ok <- state.ops.write_synced(temp, toml),
         {:ok, ^toml} <- bounded_read(temp, 1_048_576, state.ops),
         {:ok, _} <- ConfigSpec.decode(toml),
         :ok <- state.ops.rename(temp, target),
         :ok <- state.ops.sync_path(dir) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :snapshot_readback_mismatch}
    end
  end

  defp write_pointer(state, pointer) do
    temp = temp_path(state.dir)
    target = Path.join(state.dir, "current")
    bytes = pointer_bytes(pointer)

    with :ok <- state.ops.write_synced(temp, bytes),
         {:ok, ^bytes} <- op(state.ops, :read, [temp]),
         :ok <- state.ops.rename(temp, target) do
      case state.ops.sync_path(state.dir) do
        :ok -> :ok
        {:error, reason} -> {:error, {:post_rename, reason}}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :pointer_readback_mismatch}
    end
  end

  defp restore_pointer(state, %{active: nil}) do
    with :ok <- remove_pointer(state),
         :ok <- state.ops.sync_path(state.dir) do
      :ok
    end
  end

  defp restore_pointer(state, old), do: write_pointer(state, old)

  defp read_pointer(dir) do
    case bounded_read(Path.join(dir, "current"), 150) do
      {:ok, bytes} -> parse_pointer(bytes)
      {:error, :enoent} -> {:ok, %{active: nil, previous: nil}}
      error -> error
    end
  end

  defp parse_pointer(bytes) do
    case String.split(bytes, "\n", trim: true) do
      ["active " <> active, "previous " <> previous] ->
        if Regex.match?(@hash, active) and (previous == "none" or Regex.match?(@hash, previous)) do
          {:ok, %{active: active, previous: if(previous == "none", do: nil, else: previous)}}
        else
          {:error, :invalid_pointer}
        end

      _ ->
        {:error, :invalid_pointer}
    end
  end

  defp read_snapshot(_, nil), do: {:error, :no_previous_snapshot}

  defp read_snapshot(dir, hash) do
    with {:ok, bytes} <- bounded_read(Path.join([dir, "snapshots", hash <> ".toml"]), 1_048_576),
         true <- hash(bytes) == hash,
         {:ok, plan} <- ConfigSpec.decode(bytes) do
      {:ok, plan}
    else
      false -> {:error, :snapshot_digest_mismatch}
      error -> error
    end
  end

  defp pointer_bytes(pointer),
    do: "active #{pointer.active}\nprevious #{pointer.previous || "none"}\n"

  defp previous_valid_hash(state, new_hash) do
    candidates =
      if state.pointer.active == new_hash,
        do: [state.pointer.previous],
        else: [state.pointer.active, state.pointer.previous]

    Enum.find(candidates, fn hash -> match?({:ok, _}, read_snapshot(state.dir, hash)) end)
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp temp_path(dir),
    do: Path.join(dir, ".tmp-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}")

  defp bounded_read(path, max, ops \\ FileOps) do
    with :ok <- reject_symlink(path),
         {:ok, %{type: :regular, size: size}} when size <= max <- File.stat(path),
         {:ok, bytes} <- op(ops, :read, [path]),
         true <- byte_size(bytes) <= max do
      {:ok, bytes}
    else
      {:ok, _} -> {:error, :too_large_or_not_regular}
      false -> {:error, :too_large}
      error -> error
    end
  end

  defp reject_symlinks(path) do
    path
    |> Path.split()
    |> Enum.reduce_while("", fn part, prefix ->
      next = if prefix == "" and part == "/", do: "/", else: Path.join(prefix, part)

      case reject_symlink(next) do
        :ok -> {:cont, next}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp check_existing_journal(dir, pointer, worker_id) do
    case bounded_read(Path.join(dir, "journal/transition.toml"), TransitionJournal.max_bytes()) do
      {:error, :enoent} ->
        :ok

      {:ok, bytes} ->
        with {:ok, record} <- TransitionJournal.decode(bytes),
             true <- record["worker_id"] == worker_id and related_pointer?(record, pointer) do
          if record["phase"] == "complete", do: :ok, else: {:error, :transition_pending}
        else
          false -> {:error, :unrelated_transition_journal}
          error -> error
        end

      error ->
        error
    end
  end

  defp selected_hash(_dir, _pointer, nil), do: {:ok, nil}

  defp selected_hash(dir, pointer, plan) do
    case Enum.find([pointer.active, pointer.previous], &(read_snapshot(dir, &1) == {:ok, plan})) do
      nil -> {:error, :base_snapshot_missing}
      selected -> {:ok, selected}
    end
  end

  defp journal_recovery(state) do
    path = Path.join(state.dir, "journal/transition.toml")

    case bounded_read(path, TransitionJournal.max_bytes()) do
      {:error, :enoent} ->
        {:legacy, %{state | transition: nil}}

      {:ok, bytes} ->
        with {:ok, record} <- TransitionJournal.decode(bytes),
             {:ok, pointer} <- read_pointer(state.dir),
             true <- related_pointer?(record, pointer),
             {:ok, plan} <- journal_plan(state.dir, record, pointer),
             true <- is_nil(plan) or plan["worker_id"] == record["worker_id"] do
          warning = recovery_warning(state.dir, pointer, plan)
          {{:ok, plan}, %{state | pointer: pointer, transition: record, error: warning}}
        else
          false ->
            {{:error, :unrelated_transition_journal},
             %{state | error: :unrelated_transition_journal}}

          {:error, reason} ->
            {{:error, reason}, %{state | error: reason}}
        end

      {:error, reason} ->
        {{:error, reason}, %{state | error: reason}}
    end
  end

  defp related_pointer?(record, pointer) do
    base = %{
      active: optional_hash(record["base_active"]),
      previous: optional_hash(record["base_previous"])
    }

    candidate = %{active: record["candidate_hash"], previous: optional_hash(record["base_hash"])}
    pointer == base or pointer == candidate
  end

  defp recovery_warning(dir, pointer, plan) do
    case read_snapshot(dir, pointer.active) do
      {:error, reason} when not is_nil(plan) and not is_nil(pointer.active) ->
        {:recovered_previous, reason}

      _ ->
        nil
    end
  end

  defp dispatched?(record), do: match?(%{"status" => "dispatched"}, List.last(record["actions"]))
  defp accepted_actions?(record), do: Enum.all?(record["actions"], &(&1["status"] == "accepted"))

  defp journal_plan(dir, record, pointer) do
    committed = record["phase"] == "pointer_committed" or record["outcome"] == "committed"

    cond do
      committed and pointer.active != record["candidate_hash"] ->
        {:error, :transition_pointer_mismatch}

      committed ->
        case read_snapshot(dir, record["candidate_hash"]) do
          {:ok, plan} ->
            {:ok, plan}

          {:error, reason} ->
            if record["phase"] == "complete",
              do: read_snapshot(dir, optional_hash(record["base_hash"])),
              else: {:error, reason}
        end

      record["base_hash"] == "none" ->
        {:error, :interrupted_first_boot}

      true ->
        read_snapshot(dir, record["base_hash"])
    end
  end

  defp synchronize_recovery(state) do
    with :ok <- state.ops.sync_path(Path.join(state.dir, "snapshots")),
         :ok <- state.ops.sync_path(Path.join(state.dir, "journal")),
         :ok <- state.ops.sync_path(state.dir) do
      :ok
    end
  end

  defp restore_base(state) do
    base = %{
      active: optional_hash(state.transition["base_active"]),
      previous: optional_hash(state.transition["base_previous"])
    }

    with {:ok, pointer} <- read_pointer(state.dir) do
      if pointer == base, do: :ok, else: restore_pointer(state, base)
    end
  end

  defp remove_pointer(state) do
    case op(state.ops, :remove, [Path.join(state.dir, "current")]) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  defp journal_reply(state, record) do
    case persist_journal(state, record) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  defp persist_journal(state, record) do
    dir = Path.join(state.dir, "journal")
    target = Path.join(dir, "transition.toml")
    temp = temp_path(dir)

    result =
      with :ok <- reject_symlinks(target),
           {:ok, bytes} <- TransitionJournal.encode(record),
           :ok <- ensure_journal_dir(state, dir),
           :ok <- state.ops.write_synced(temp, bytes),
           {:ok, ^bytes} <- bounded_read(temp, TransitionJournal.max_bytes(), state.ops),
           {:ok, ^record} <- TransitionJournal.decode(bytes),
           :ok <- state.ops.rename(temp, target),
           :ok <- state.ops.sync_path(dir) do
        :ok
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :journal_readback_mismatch}
      end

    case result do
      :ok ->
        warning =
          case state.error do
            {:recovered_previous, _} = reason -> reason
            _ -> nil
          end

        {:ok, %{state | transition: record, uncertain: nil, error: warning}}

      {:error, reason} ->
        failure = {:journal_failed, record["phase"], reason}
        {:error, failure, %{state | error: failure, uncertain: failure}}
    end
  end

  defp ensure_journal_dir(state, dir) do
    case File.lstat(dir) do
      {:ok, %{type: :directory}} ->
        state.ops.sync_path(state.dir)

      {:error, :enoent} ->
        with :ok <- File.mkdir(dir), do: state.ops.sync_path(state.dir)

      {:ok, _} ->
        {:error, :invalid_journal_directory}

      error ->
        error
    end
  end

  defp advance(record, changes),
    do: Map.merge(record, changes) |> Map.update!("sequence", &(&1 + 1))

  defp optional_hash("none"), do: nil
  defp optional_hash(hash), do: hash

  defp bounded_detail(result),
    do: inspect(result, limit: 8, printable_limit: 128) |> String.slice(0, 64)

  defp op(ops, operation, arguments) do
    module = if function_exported?(ops, operation, length(arguments)), do: ops, else: FileOps
    apply(module, operation, arguments)
  end

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> {:error, :symlink_path}
      {:ok, _} -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end
end
