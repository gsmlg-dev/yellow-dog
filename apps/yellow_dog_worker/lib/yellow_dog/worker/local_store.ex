defmodule YellowDog.Worker.LocalStore do
  @moduledoc """
  Owns a Worker data directory and commits immutable, self-contained TOML plans.

  A Linux flock child holds the directory lock for this process's lifetime. A
  single pointer file names the active and previous snapshots. Snapshots are
  written, synced, and decoded again before the pointer can reference them.
  """

  use GenServer

  alias YellowDog.ConfigSpec
  alias YellowDog.Worker.FileOps

  @hash ~r/\A[0-9a-f]{64}\z/

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def recover(pid), do: GenServer.call(pid, :recover)
  def prepare(pid, plan), do: GenServer.call(pid, {:prepare, plan}, 30_000)
  def commit(pid, candidate), do: GenServer.call(pid, {:commit, candidate}, 30_000)
  def status(pid), do: GenServer.call(pid, :status)

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
         uncertain: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:recover, _from, %{uncertain: error} = state) when not is_nil(error) do
    # Readable bytes do not establish durability after a failed sync and failed
    # rollback. Only a new successful commit may clear this state.
    {:reply, {:error, error}, state}
  end

  def handle_call(:recover, _from, state) do
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
    if Map.has_key?(state.prepared, hash) do
      previous_pointer = state.pointer
      new_pointer = %{active: hash, previous: previous_valid_hash(state, hash)}

      case write_pointer(state, new_pointer) do
        :ok ->
          {:reply, :ok,
           %{
             state
             | pointer: new_pointer,
               prepared: Map.delete(state.prepared, hash),
               error: nil,
               uncertain: nil
           }}

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
    else
      {:reply, {:error, :unknown_candidate}, state}
    end
  end

  def handle_call({:commit, _}, _from, state), do: {:reply, {:error, :unknown_candidate}, state}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       active: state.pointer.active,
       previous: state.pointer.previous,
       prepared: Map.keys(state.prepared),
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
        :ok

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
         {:ok, ^toml} <- bounded_read(temp, 1_048_576),
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
         {:ok, ^bytes} <- File.read(temp),
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
    with :ok <- File.rm(Path.join(state.dir, "current")),
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

  defp bounded_read(path, max) do
    with :ok <- reject_symlink(path),
         {:ok, %{type: :regular, size: size}} when size <= max <- File.stat(path),
         {:ok, bytes} <- File.read(path),
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

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> {:error, :symlink_path}
      {:ok, _} -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end
end
