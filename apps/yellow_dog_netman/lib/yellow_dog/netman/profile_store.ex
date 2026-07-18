defmodule YellowDog.Netman.ProfileStore do
  @moduledoc """
  TOML-based connection profile management with hot-reload.

  Reads profile files from the configured directory on startup,
  watches for changes via `file_system`, and provides CRUD operations.
  """

  @compile {:no_warn_undefined, [Toml, FileSystem]}

  use GenServer

  require Logger

  alias YellowDog.Netman.EventBus
  alias YellowDog.Netman.Types.Profile

  @default_profile_dir "/etc/yellowdog/netman/profiles"
  @max_profile_file_bytes 1_048_576
  @max_temp_attempts 8
  @watcher_debounce_ms 200
  @watcher_change_events [
    :created,
    :modified,
    :removed,
    :deleted,
    :renamed,
    :moved_from,
    :moved_to
  ]

  defstruct [
    :profile_dir,
    :watcher_pid,
    :debounce_ref,
    :file_ops,
    profiles: %{},
    revisions: %{},
    # Reverse mapping: file path → profile ID, for detecting ID changes on reload
    path_ids: %{},
    pending_reloads: MapSet.new()
  ]

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc "List all profiles."
  @spec list() :: [Profile.t()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Get a profile by ID."
  @spec get(String.t()) :: {:ok, Profile.t()} | {:error, :not_found}
  def get(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  @doc "Durably store a profile."
  @spec put(String.t(), Profile.t()) :: :ok | {:error, term()}
  def put(id, %Profile{} = profile) do
    put(id, profile, [])
  end

  @doc "Durably store a profile if its current revision matches the expected revision."
  @spec put(String.t(), Profile.t(), keyword()) :: :ok | {:error, term()}
  def put(id, %Profile{} = profile, opts) do
    GenServer.call(__MODULE__, {:put, id, profile, opts})
  end

  @doc "Delete a profile by ID."
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(id) do
    delete(id, [])
  end

  @doc "Delete a profile if its current revision matches the expected revision."
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(id, opts) do
    GenServer.call(__MODULE__, {:delete, id, opts})
  end

  @doc "Return the canonical revision for a profile."
  @spec revision(String.t()) :: {:ok, String.t()} | {:error, :not_found | :invalid_id}
  def revision(id) do
    GenServer.call(__MODULE__, {:revision, id})
  end

  @doc "Import a profile from a TOML file."
  @spec import_file(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def import_file(path) do
    GenServer.call(__MODULE__, {:import_file, path})
  end

  @doc "Find the best matching profile for an interface."
  @spec match_interface(String.t(), atom()) :: Profile.t() | nil
  def match_interface(interface, type \\ :ethernet) do
    GenServer.call(__MODULE__, {:match_interface, interface, type})
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    profile_dir =
      Keyword.get_lazy(opts, :profile_dir, fn ->
        Application.get_env(:yellow_dog_netman, :profile_dir, @default_profile_dir)
      end)

    file_ops = Keyword.get(opts, :file_ops, __MODULE__.FileOps)

    with :ok <- safe_mkdir_p(file_ops, profile_dir) do
      {profiles, path_ids, revisions} = load_profiles(profile_dir)
      watcher_pid = if Keyword.get(opts, :watcher, true), do: start_watcher(profile_dir)

      {:ok,
       %__MODULE__{
         profile_dir: profile_dir,
         watcher_pid: watcher_pid,
         file_ops: file_ops,
         profiles: profiles,
         revisions: revisions,
         path_ids: path_ids
       }}
    else
      {:error, reason} -> {:stop, {:profile_directory_unavailable, reason}}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    profiles = Map.values(state.profiles)
    {:reply, profiles, state}
  end

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state.profiles, id) do
      {:ok, profile} -> {:reply, {:ok, profile}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:revision, id}, _from, state) when is_binary(id) do
    with :ok <- valid_filename_id(id) do
      case Map.fetch(state.revisions, id) do
        {:ok, revision} -> {:reply, {:ok, revision}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    else
      {:error, :invalid_id} = error -> {:reply, error, state}
    end
  end

  def handle_call({:revision, _id}, _from, state) do
    {:reply, {:error, :invalid_id}, state}
  end

  def handle_call({:put, id, profile}, _from, state) do
    handle_put(id, profile, [], state)
  end

  def handle_call({:put, id, profile, opts}, _from, state) do
    handle_put(id, profile, opts, state)
  end

  def handle_call({:delete, id}, _from, state) do
    handle_delete(id, [], state)
  end

  def handle_call({:delete, id, opts}, _from, state) do
    handle_delete(id, opts, state)
  end

  def handle_call({:import_file, path}, _from, state) do
    if valid_profile_path?(path) do
      case parse_toml_file(path) do
        {:ok, profile} ->
          profiles = Map.put(state.profiles, profile.id, profile)
          revisions = Map.put(state.revisions, profile.id, profile_revision(profile))
          path_ids = Map.put(state.path_ids, path, profile.id)
          EventBus.publish("netman:profile:changed", {:added, profile.id})

          {:reply, {:ok, profile},
           %{state | profiles: profiles, revisions: revisions, path_ids: path_ids}}

        {:error, _} = error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :invalid_path}, state}
    end
  end

  def handle_call({:match_interface, interface, type}, _from, state) do
    profile =
      state.profiles
      |> Map.values()
      |> Enum.filter(fn p ->
        p.type == type and
          (p.interface == nil or p.interface == interface)
      end)
      |> Enum.sort_by(fn p ->
        # Prefer exact interface match, then by priority, then by id for determinism
        {if(p.interface == interface, do: 0, else: 1), -p.autoconnect_priority, p.id}
      end)
      |> List.first()

    {:reply, profile, state}
  end

  defp handle_put(id, profile, opts, state) do
    with :ok <- validate_mutation_options(opts),
         {:ok, profile, contents, revision} <- prepare_profile(id, profile),
         path = profile_path(state.profile_dir, id),
         :ok <- check_expected_revision(state, id, path, opts),
         :ok <- durable_write(path, contents, state.file_ops) do
      profiles = Map.put(state.profiles, id, profile)
      revisions = Map.put(state.revisions, id, revision)
      path_ids = Map.put(state.path_ids, path, id)

      EventBus.publish("netman:profile:changed", {:updated, id})

      {:reply, :ok, %{state | profiles: profiles, revisions: revisions, path_ids: path_ids}}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp handle_delete(id, opts, state) do
    with :ok <- validate_mutation_options(opts),
         :ok <- valid_filename_id(id),
         true <- Map.has_key?(state.profiles, id),
         path = profile_path(state.profile_dir, id),
         :ok <- check_expected_revision(state, id, path, opts),
         profile_paths = owned_profile_paths(state, id),
         :ok <- durable_delete_all(profile_paths, state.file_ops) do
      profile_paths = MapSet.new(profile_paths)

      path_ids =
        state.path_ids
        |> Enum.reject(fn {_path, profile_id} -> profile_id == id end)
        |> Map.new()

      pending_reloads = MapSet.difference(state.pending_reloads, profile_paths)
      EventBus.publish("netman:profile:changed", {:deleted, id})

      {:reply, :ok,
       %{
         state
         | profiles: Map.delete(state.profiles, id),
           revisions: Map.delete(state.revisions, id),
           path_ids: path_ids,
           pending_reloads: pending_reloads
       }}
    else
      false -> {:reply, {:error, :not_found}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    cond do
      Path.extname(path) != ".toml" ->
        {:noreply, state}

      Enum.any?(events, &(&1 in @watcher_change_events)) ->
        {:noreply, enqueue_reload(state, path)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:flush_pending_reloads, state) do
    state =
      Enum.reduce(state.pending_reloads, state, fn path, acc ->
        Logger.info("Profile file changed: #{path}")

        cond do
          symlink?(path) -> remove_deleted_path(acc, path)
          File.exists?(path) -> reload_profile(acc, path)
          true -> remove_deleted_path(acc, path)
        end
      end)

    {:noreply, %{state | pending_reloads: MapSet.new(), debounce_ref: nil}}
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("Profile directory watcher stopped")
    {:noreply, %{state | watcher_pid: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)

    if state.watcher_pid && Process.alive?(state.watcher_pid) do
      GenServer.stop(state.watcher_pid, :normal, 1_000)
    end

    :ok
  end

  ## Internal

  defp prepare_profile(id, %Profile{id: profile_id} = profile) when id == profile_id do
    with :ok <- valid_filename_id(id),
         {:ok, validated} <- validate_profile(profile) do
      contents = Profile.canonical_toml(validated)
      {:ok, validated, contents, revision_for_contents(contents)}
    end
  end

  defp prepare_profile(id, %Profile{}) when is_binary(id),
    do: {:error, :profile_id_mismatch}

  defp prepare_profile(_id, %Profile{}),
    do: {:error, {:invalid_profile, "connection.id must be a string"}}

  defp validate_profile(profile) do
    case profile |> Profile.to_toml() |> Profile.from_toml() do
      {:ok, validated} -> {:ok, validated}
      {:error, reason} -> {:error, {:invalid_profile, reason}}
    end
  end

  defp valid_filename_id(id) do
    case Profile.validate_id(id) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_id}
    end
  end

  defp validate_mutation_options([]), do: :ok

  defp validate_mutation_options(expected_revision: revision)
       when is_binary(revision) and byte_size(revision) == 64 do
    if String.match?(revision, ~r/\A[0-9a-f]{64}\z/) do
      :ok
    else
      {:error, :invalid_revision}
    end
  end

  defp validate_mutation_options(expected_revision: _revision),
    do: {:error, :invalid_revision}

  defp validate_mutation_options(_opts), do: {:error, :invalid_options}

  defp check_expected_revision(state, id, path, opts) do
    case Keyword.fetch(opts, :expected_revision) do
      :error ->
        :ok

      {:ok, expected_revision} ->
        case current_revision(state, id, path) do
          {:ok, ^expected_revision} -> :ok
          {:ok, current_revision} -> {:error, {:conflict, current_revision}}
          {:error, _reason} = error -> error
        end
    end
  end

  defp current_revision(state, id, path) do
    case parse_toml_file(path) do
      {:ok, %Profile{id: ^id} = profile} ->
        {:ok, profile_revision(profile)}

      {:ok, %Profile{}} ->
        {:error, :profile_id_mismatch}

      {:error, {:file_read, :enoent}} ->
        case Map.fetch(state.revisions, id) do
          {:ok, revision} -> {:ok, revision}
          :error -> {:error, :not_found}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp profile_revision(profile) do
    profile
    |> Profile.canonical_toml()
    |> revision_for_contents()
  end

  defp revision_for_contents(contents) do
    :crypto.hash(:sha256, contents)
    |> Base.encode16(case: :lower)
  end

  defp profile_path(profile_dir, id), do: Path.join(profile_dir, "#{id}.toml")

  defp owned_profile_paths(state, id) do
    canonical_path = profile_path(state.profile_dir, id)

    aliases =
      state.path_ids
      |> Enum.flat_map(fn
        {path, ^id} -> [path]
        {_path, _other_id} -> []
      end)
      |> Enum.filter(&managed_profile_path?(&1, state.profile_dir))
      |> Enum.reject(&(&1 == canonical_path))
      |> Enum.uniq()
      |> Enum.sort()

    aliases ++ [canonical_path]
  end

  defp managed_profile_path?(path, profile_dir) do
    expanded_path = Path.expand(path)
    expanded_dir = Path.expand(profile_dir)

    Path.dirname(expanded_path) == expanded_dir and Path.extname(expanded_path) == ".toml"
  end

  defp valid_profile_path?(path) when is_binary(path) do
    not String.contains?(path, "\0") and
      Path.extname(path) == ".toml" and
      byte_size(path) <= 4096 and
      not symlink?(path)
  end

  defp valid_profile_path?(_), do: false

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _ -> false
    end
  end

  defp load_profiles(dir) do
    if File.dir?(dir) do
      {profiles, path_ids, revisions, _canonical_ids} =
        dir
        |> Path.join("*.toml")
        |> Path.wildcard()
        |> Enum.reject(&symlink?/1)
        |> Enum.reduce(
          {%{}, %{}, %{}, MapSet.new()},
          fn path, {profiles, path_ids, revisions, canonical_ids} ->
            case parse_toml_file(path) do
              {:ok, profile} ->
                canonical? = path == profile_path(dir, profile.id)

                {profiles, revisions} =
                  if canonical? or not MapSet.member?(canonical_ids, profile.id) do
                    {
                      Map.put(profiles, profile.id, profile),
                      Map.put(revisions, profile.id, profile_revision(profile))
                    }
                  else
                    {profiles, revisions}
                  end

                canonical_ids =
                  if canonical?, do: MapSet.put(canonical_ids, profile.id), else: canonical_ids

                {profiles, Map.put(path_ids, path, profile.id), revisions, canonical_ids}

              {:error, reason} ->
                Logger.warning("Failed to parse profile #{path}: #{inspect(reason)}")
                {profiles, path_ids, revisions, canonical_ids}
            end
          end
        )

      {profiles, path_ids, revisions}
    else
      Logger.info("Profile directory does not exist: #{dir}")
      {%{}, %{}, %{}}
    end
  end

  defp parse_toml_file(path) do
    with {:ok, path_info} <- profile_file_info(path),
         {:ok, device} <- open_profile_file(path) do
      try do
        with {:ok, device_info} <- open_file_info(device),
             :ok <- same_file(path_info, device_info),
             {:ok, current_path_info} <- profile_file_info(path),
             :ok <- same_file(current_path_info, device_info),
             {:ok, content} <- read_profile_file(device, 0, []) do
          case Toml.decode(content) do
            {:ok, toml} -> Profile.from_toml(toml)
            {:error, reason} -> {:error, {:toml_parse, reason}}
          end
        end
      after
        _result = :file.close(device)
      end
    end
  end

  defp profile_file_info(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size} = info} when size <= @max_profile_file_bytes ->
        {:ok, info}

      {:ok, %{type: :regular, size: size}} ->
        {:error, {:file_too_large, size, @max_profile_file_bytes}}

      {:ok, %{type: :symlink}} ->
        {:error, {:symlink_rejected, path}}

      {:ok, %{type: type}} ->
        {:error, {:not_regular_file, type}}

      {:error, reason} ->
        {:error, {:file_read, reason}}
    end
  end

  defp open_profile_file(path) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, device} -> {:ok, device}
      {:error, reason} -> {:error, {:file_read, reason}}
    end
  end

  defp open_file_info(device) do
    case :file.read_file_info(device) do
      {:ok, info} when is_tuple(info) and tuple_size(info) >= 12 ->
        {:ok,
         %{
           size: elem(info, 1),
           type: elem(info, 2),
           major_device: elem(info, 9),
           minor_device: elem(info, 10),
           inode: elem(info, 11)
         }}

      {:error, reason} ->
        {:error, {:file_read, reason}}

      _unexpected ->
        {:error, {:file_read, :invalid_file_info}}
    end
  end

  defp same_file(
         %{type: :regular, major_device: major, minor_device: minor, inode: inode},
         %{type: :regular, major_device: major, minor_device: minor, inode: inode}
       ),
       do: :ok

  defp same_file(_path_info, _device_info), do: {:error, {:file_read, :file_replaced}}

  defp read_profile_file(device, size, chunks) do
    case :file.read(device, 64 * 1024) do
      :eof ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, content} ->
        new_size = size + byte_size(content)

        if new_size <= @max_profile_file_bytes do
          read_profile_file(device, new_size, [content | chunks])
        else
          {:error, {:file_too_large, new_size, @max_profile_file_bytes}}
        end

      {:error, reason} ->
        {:error, {:file_read, reason}}
    end
  end

  defp start_watcher(dir) do
    if File.dir?(dir) do
      case FileSystem.start_link(dirs: [dir]) do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          pid

        :ignore ->
          Logger.info("Profile watcher not started (ignored)")
          nil

        {:error, reason} ->
          Logger.warning("Failed to start profile watcher: #{inspect(reason)}")
          nil
      end
    else
      nil
    end
  end

  defp enqueue_reload(state, path) do
    pending_reloads = MapSet.put(state.pending_reloads, path)

    debounce_ref =
      state.debounce_ref ||
        Process.send_after(self(), :flush_pending_reloads, @watcher_debounce_ms)

    %{state | pending_reloads: pending_reloads, debounce_ref: debounce_ref}
  end

  defp remove_deleted_path(state, path) do
    case Map.pop(state.path_ids, path) do
      {nil, _path_ids} ->
        state

      {id, path_ids} ->
        pending_reloads = MapSet.delete(state.pending_reloads, path)
        canonical_path = profile_path(state.profile_dir, id)

        if path != canonical_path and File.regular?(canonical_path) do
          reload_profile(
            %{state | path_ids: path_ids, pending_reloads: pending_reloads},
            canonical_path
          )
        else
          EventBus.publish("netman:profile:changed", {:deleted, id})

          path_ids =
            path_ids
            |> Enum.reject(fn {_other_path, profile_id} -> profile_id == id end)
            |> Map.new()

          %{
            state
            | profiles: Map.delete(state.profiles, id),
              revisions: Map.delete(state.revisions, id),
              path_ids: path_ids,
              pending_reloads: pending_reloads
          }
        end
    end
  end

  defp reload_profile(state, path) do
    case parse_toml_file(path) do
      {:ok, profile} ->
        canonical_path = profile_path(state.profile_dir, profile.id)

        if path != canonical_path and File.regular?(canonical_path) do
          state
          |> Map.update!(:path_ids, &Map.put(&1, path, profile.id))
          |> reload_profile(canonical_path)
        else
          apply_reloaded_profile(state, path, profile)
        end

      {:error, reason} ->
        Logger.warning("Failed to reload profile #{path}: #{inspect(reason)}")
        state
    end
  end

  defp apply_reloaded_profile(state, path, profile) do
    # If the profile ID changed, remove the old entry.
    old_id = Map.get(state.path_ids, path)
    revision = profile_revision(profile)

    if old_id == profile.id and Map.get(state.revisions, profile.id) == revision do
      %{state | path_ids: Map.put(state.path_ids, path, profile.id)}
    else
      {profiles, revisions} =
        if old_id && old_id != profile.id do
          Logger.info("Profile ID changed from #{old_id} to #{profile.id} in #{path}")
          EventBus.publish("netman:profile:changed", {:deleted, old_id})

          {
            state.profiles |> Map.delete(old_id) |> Map.put(profile.id, profile),
            state.revisions |> Map.delete(old_id) |> Map.put(profile.id, revision)
          }
        else
          {
            Map.put(state.profiles, profile.id, profile),
            Map.put(state.revisions, profile.id, revision)
          }
        end

      path_ids = Map.put(state.path_ids, path, profile.id)
      EventBus.publish("netman:profile:changed", {:reloaded, profile.id})
      %{state | profiles: profiles, revisions: revisions, path_ids: path_ids}
    end
  end

  defp durable_write(path, contents, file_ops) do
    with :ok <- safe_mkdir_p(file_ops, Path.dirname(path)),
         {:ok, temporary_path, device} <- open_temporary(path, file_ops) do
      result =
        with :ok <- write_sync_close(device, contents, file_ops),
             :ok <- rename_temporary(temporary_path, path, file_ops) do
          :ok
        end

      case result do
        :ok ->
          best_effort_sync_dir(file_ops, Path.dirname(path), :rename)
          :ok

        {:error, reason} ->
          best_effort_remove(file_ops, temporary_path)
          {:error, {:write_failed, reason}}
      end
    else
      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  defp open_temporary(path, file_ops, attempt \\ 0)

  defp open_temporary(_path, _file_ops, @max_temp_attempts), do: {:error, :eexist}

  defp open_temporary(path, file_ops, attempt) do
    temporary_path =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{random_suffix()}.tmp"
      )

    case file_ops.open(temporary_path) do
      {:ok, device} ->
        {:ok, temporary_path, device}

      {:error, :eexist} ->
        open_temporary(path, file_ops, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_sync_close(device, contents, file_ops) do
    write_result =
      with :ok <- file_ops.write(device, contents),
           :ok <- file_ops.sync(device) do
        :ok
      end

    close_result = file_ops.close(device)

    case {write_result, close_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _close_result} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, {:close, reason}}
    end
  end

  defp rename_temporary(temporary_path, path, file_ops) do
    case file_ops.rename(temporary_path, path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp durable_delete(path, file_ops) do
    case file_ops.rm(path) do
      :ok ->
        best_effort_sync_dir(file_ops, Path.dirname(path), :unlink)
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:delete_failed, reason}}
    end
  end

  defp durable_delete_all(paths, file_ops) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case durable_delete(path, file_ops) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp safe_mkdir_p(file_ops, path) do
    try do
      case file_ops.mkdir_p(path) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        unexpected -> {:error, {:unexpected_return, unexpected}}
      end
    rescue
      exception -> {:error, {:exception, exception}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp best_effort_sync_dir(file_ops, directory, commit_operation) do
    result =
      try do
        file_ops.sync_dir(directory)
      rescue
        exception -> {:raised, exception}
      catch
        kind, reason -> {:caught, kind, reason}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        log_directory_sync_failure(commit_operation, reason)

      {:raised, exception} ->
        log_directory_sync_failure(commit_operation, exception)

      {:caught, kind, reason} ->
        log_directory_sync_failure(commit_operation, {kind, reason})

      unexpected ->
        log_directory_sync_failure(commit_operation, {:unexpected_return, unexpected})
    end

    :ok
  end

  defp log_directory_sync_failure(commit_operation, reason) do
    Logger.warning(
      "Failed to sync profile directory after #{commit_operation}: #{inspect(reason)}"
    )
  end

  defp best_effort_remove(file_ops, path) do
    file_ops.rm(path)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(18)
    |> Base.url_encode64(padding: false)
  end
end

defmodule YellowDog.Netman.ProfileStore.FileOps do
  @moduledoc false

  def mkdir_p(path), do: File.mkdir_p(path)
  def open(path), do: :file.open(path, [:write, :exclusive, :binary, :raw])
  def write(device, contents), do: :file.write(device, contents)
  def sync(device), do: :file.sync(device)
  def close(device), do: :file.close(device)
  def rename(source, target), do: File.rename(source, target)
  def rm(path), do: File.rm(path)

  def sync_dir(directory) do
    with {:ok, device} <- :file.open(directory, [:read, :raw, :directory]) do
      result =
        case :file.sync(device) do
          {:error, :enotsup} -> :ok
          other -> other
        end

      close_result = :file.close(device)

      case {result, close_result} do
        {:ok, :ok} -> :ok
        {{:error, reason}, _close_result} -> {:error, reason}
        {:ok, {:error, reason}} -> {:error, {:close, reason}}
      end
    else
      {:error, :enotsup} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
