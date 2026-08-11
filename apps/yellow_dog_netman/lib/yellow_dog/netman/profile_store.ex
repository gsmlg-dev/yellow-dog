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
  @history_directory ".history"
  @active_directory ".active"
  @replacement_journal ".replace-rollback.json"
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
    :clock,
    profiles: %{},
    revisions: %{},
    history: %{},
    active_revisions: %{},
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

  @doc "List profile lifecycle states with one namespace revision snapshot."
  @spec list_states() :: {[map()], String.t()}
  def list_states do
    GenServer.call(__MODULE__, :list_states)
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

  @doc """
  Durably store a profile if its current revision matches the expected revision.

  Pass `expected_revision: :missing` to require that the profile is absent.
  """
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

  @doc "Return a profile together with its desired and active revisions."
  @spec state(String.t()) ::
          {:ok,
           %{
             profile: Profile.t(),
             desired_revision: String.t(),
             active_revision: String.t() | nil
           }}
          | {:error, :not_found | :invalid_id}
  def state(id) do
    GenServer.call(__MODULE__, {:state, id})
  end

  @doc "List immutable revisions for a profile, newest desired revision first."
  @spec history(String.t()) :: {:ok, [map()]} | {:error, :not_found | :invalid_id}
  def history(id) do
    GenServer.call(__MODULE__, {:history, id})
  end

  @doc "Return the deterministic revision for the complete profile namespace."
  @spec namespace_revision() :: {:ok, String.t()}
  def namespace_revision do
    GenServer.call(__MODULE__, :namespace_revision)
  end

  @doc "Return profiles and their namespace revision from one store snapshot."
  @spec namespace_snapshot() :: {[Profile.t()], String.t()}
  def namespace_snapshot do
    GenServer.call(__MODULE__, :namespace_snapshot)
  end

  @doc "Record a revision as active after its synchronous reconciliation succeeded."
  @spec mark_active(String.t(), String.t()) :: :ok | {:error, term()}
  def mark_active(id, revision) do
    GenServer.call(__MODULE__, {:mark_active, id, revision})
  end

  @doc "Restore an immutable revision as the desired profile."
  @spec rollback(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def rollback(id, target_revision, opts \\ []) do
    GenServer.call(__MODULE__, {:rollback, id, target_revision, opts})
  end

  @doc "Replace the complete runtime profile namespace."
  @spec replace([Profile.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def replace(profiles, opts \\ []) do
    GenServer.call(__MODULE__, {:replace, profiles, opts}, 30_000)
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
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    with :ok <- safe_mkdir_p(file_ops, profile_dir),
         :ok <- recover_pending_replacement(profile_dir, file_ops) do
      {profiles, path_ids, revisions} = load_profiles(profile_dir)
      history = load_history(profile_dir)

      case ensure_current_history(
             history,
             profiles,
             revisions,
             profile_dir,
             file_ops,
             clock
           ) do
        {:ok, history} ->
          active_revisions = load_active_revisions(profile_dir, profiles, history)
          watcher_pid = if Keyword.get(opts, :watcher, true), do: start_watcher(profile_dir)

          {:ok,
           %__MODULE__{
             profile_dir: profile_dir,
             watcher_pid: watcher_pid,
             file_ops: file_ops,
             clock: clock,
             profiles: profiles,
             revisions: revisions,
             history: history,
             active_revisions: active_revisions,
             path_ids: path_ids
           }}

        {:error, reason} ->
          {:stop, {:profile_history_unavailable, reason}}
      end
    else
      {:error, {:replacement_recovery_failed, _reason} = reason} -> {:stop, reason}
      {:error, reason} -> {:stop, {:profile_directory_unavailable, reason}}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    profiles = Map.values(state.profiles)
    {:reply, profiles, state}
  end

  def handle_call(:list_states, _from, state) do
    states =
      state.profiles
      |> Map.values()
      |> Enum.map(fn profile ->
        %{
          profile: profile,
          desired_revision: Map.fetch!(state.revisions, profile.id),
          active_revision: active_revision(state, profile.id)
        }
      end)

    {:reply, {states, profile_states_revision(states)}, state}
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

  def handle_call({:state, id}, _from, state) when is_binary(id) do
    with :ok <- valid_filename_id(id),
         {:ok, profile} <- Map.fetch(state.profiles, id),
         {:ok, desired_revision} <- Map.fetch(state.revisions, id) do
      active_revision = active_revision(state, id)

      {:reply,
       {:ok,
        %{
          profile: profile,
          desired_revision: desired_revision,
          active_revision: active_revision
        }}, state}
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, :invalid_id} = error -> {:reply, error, state}
    end
  end

  def handle_call({:state, _id}, _from, state) do
    {:reply, {:error, :invalid_id}, state}
  end

  def handle_call({:history, id}, _from, state) when is_binary(id) do
    with :ok <- valid_filename_id(id),
         {:ok, entries} <- Map.fetch(state.history, id) do
      {:reply, {:ok, order_history(entries, Map.get(state.revisions, id))}, state}
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, :invalid_id} = error -> {:reply, error, state}
    end
  end

  def handle_call({:history, _id}, _from, state) do
    {:reply, {:error, :invalid_id}, state}
  end

  def handle_call(:namespace_revision, _from, state) do
    {:reply, {:ok, namespace_revision_for(state.revisions)}, state}
  end

  def handle_call(:namespace_snapshot, _from, state) do
    profiles = state.profiles |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, {profiles, namespace_revision_for(state.revisions)}, state}
  end

  def handle_call({:mark_active, id, revision}, _from, state) do
    case mark_active_state(state, id, revision) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:rollback, id, target_revision, opts}, _from, state) do
    case rollback_state(state, id, target_revision, opts) do
      {:ok, revision, state} -> {:reply, {:ok, revision}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replace, profiles, opts}, _from, state) do
    case replace_state(state, profiles, opts) do
      {:ok, revision, state} ->
        {:reply, {:ok, revision}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}

      {:fatal, reason, state} ->
        {:stop, reason, {:error, {:replacement_recovery_failed, reason}}, state}
    end
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
          revision = profile_revision(profile)

          case ensure_history_entry(state, profile, revision) do
            {:ok, state} ->
              profiles = Map.put(state.profiles, profile.id, profile)
              revisions = Map.put(state.revisions, profile.id, revision)
              path_ids = Map.put(state.path_ids, path, profile.id)
              state = %{state | profiles: profiles, revisions: revisions, path_ids: path_ids}
              EventBus.publish("netman:profile:changed", {:added, profile.id})

              {:reply, {:ok, profile}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

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
    case put_state(state, id, profile, opts) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp put_state(state, id, profile, opts, publish_event? \\ true) do
    with :ok <- validate_mutation_options(opts),
         {:ok, profile, contents, revision} <- prepare_profile(id, profile),
         path = profile_path(state.profile_dir, id),
         :ok <- check_expected_revision(state, id, path, opts) do
      case ensure_history_entry(state, profile, revision) do
        {:ok, history_state} ->
          case durable_write(path, contents, state.file_ops) do
            :ok ->
              creating? = not Map.has_key?(state.profiles, id)
              profiles = Map.put(state.profiles, id, profile)
              revisions = Map.put(state.revisions, id, revision)
              path_ids = Map.put(state.path_ids, path, id)

              state = %{
                history_state
                | profiles: profiles,
                  revisions: revisions,
                  path_ids: path_ids
              }

              state = if creating?, do: clear_stale_active(state, id), else: state
              if publish_event?, do: EventBus.publish("netman:profile:changed", {:updated, id})

              {:ok, state}

            {:error, reason} ->
              {:error, reason, history_state}
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_delete(id, opts, state) do
    case delete_state(state, id, opts) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp delete_state(state, id, opts, publish_event? \\ true) do
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
      if publish_event?, do: EventBus.publish("netman:profile:changed", {:deleted, id})

      state =
        %{
          state
          | profiles: Map.delete(state.profiles, id),
            revisions: Map.delete(state.revisions, id),
            path_ids: path_ids,
            pending_reloads: pending_reloads,
            active_revisions: Map.delete(state.active_revisions, id)
        }

      best_effort_delete_active_pointer(state, id)
      {:ok, state}
    else
      false -> {:error, :not_found, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    cond do
      Path.extname(path) != ".toml" or lifecycle_metadata_path?(path, state.profile_dir) ->
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
  defp validate_mutation_options(expected_revision: :missing), do: :ok

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

      {:ok, :missing} ->
        case current_revision(state, id, path) do
          {:error, :not_found} -> :ok
          {:ok, current_revision} -> {:error, {:conflict, current_revision}}
          {:error, _reason} = error -> error
        end

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

  defp namespace_revision_for(revisions) do
    revisions
    |> Enum.sort()
    |> Enum.map(fn {id, revision} -> [id, revision] end)
    |> Jason.encode!()
    |> revision_for_contents()
  end

  defp profile_states_revision(states) do
    states
    |> Enum.map(fn state ->
      [state.profile.id, state.desired_revision, state.active_revision]
    end)
    |> Enum.sort()
    |> Jason.encode!()
    |> revision_for_contents()
  end

  defp active_revision(state, id) do
    case Map.get(state.active_revisions, id) do
      %{revision: revision} -> revision
      nil -> nil
    end
  end

  defp order_history(entries, desired_revision) do
    entries
    |> Map.values()
    |> Enum.sort_by(fn entry ->
      desired_rank = if entry.revision == desired_revision, do: 0, else: 1
      {desired_rank, -DateTime.to_unix(entry.stored_at, :microsecond), entry.revision}
    end)
  end

  defp rollback_state(state, id, target_revision, opts) do
    with :ok <- validate_mutation_options(opts),
         :ok <- valid_filename_id(id),
         :ok <- valid_revision(target_revision),
         {:ok, entries} <- Map.fetch(state.history, id),
         {:ok, entry} <- Map.fetch(entries, target_revision) do
      case put_state(state, id, entry.profile, opts) do
        {:ok, state} -> {:ok, target_revision, state}
        {:error, reason, state} -> {:error, reason, state}
      end
    else
      :error -> {:error, :revision_not_found, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp replace_state(state, profiles, opts) do
    with :ok <- validate_mutation_options(opts),
         {:ok, profiles} <- validate_replacement_profiles(profiles),
         :ok <- check_namespace_revision(state, opts),
         {:ok, journal} <- persist_replacement_journal(state, profiles) do
      case apply_replacement(state, profiles) do
        {:ok, replacement_state, omitted_ids} ->
          case commit_replacement(replacement_state) do
            {:ok, committed_state} ->
              publish_replacement_events(profiles, omitted_ids)
              {:ok, namespace_revision_for(committed_state.revisions), committed_state}

            {:error, reason} ->
              recover_failed_replacement(state, replacement_state, journal, reason)
          end

        {:error, reason, replacement_state} ->
          recover_failed_replacement(state, replacement_state, journal, reason)
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp apply_replacement(state, profiles) do
    desired_ids = MapSet.new(profiles, & &1.id)

    with {:ok, state} <- put_replacement_profiles(state, profiles) do
      omitted_ids =
        state.profiles
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(desired_ids, &1))
        |> Enum.sort()

      case delete_replacement_profiles(state, omitted_ids) do
        {:ok, state} -> {:ok, state, omitted_ids}
        {:error, reason, state} -> {:error, reason, state}
      end
    end
  end

  defp commit_replacement(state) do
    case durable_delete(replacement_journal_path(state.profile_dir), state.file_ops) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover_failed_replacement(original_state, replacement_state, journal, reason) do
    case restore_replacement(journal, replacement_state.file_ops) do
      :ok ->
        case reload_restored_state(original_state, replacement_state) do
          {:ok, restored_state} ->
            {:error, reason, restored_state}

          {:error, recovery_reason} ->
            replacement_recovery_failure(reason, recovery_reason, replacement_state)
        end

      {:error, recovery_reason} ->
        replacement_recovery_failure(reason, recovery_reason, replacement_state)
    end
  end

  defp replacement_recovery_failure(reason, recovery_reason, state) do
    fatal_reason = {:replacement_recovery_failed, %{operation: reason, recovery: recovery_reason}}
    Logger.error("Profile replacement recovery failed: #{inspect(fatal_reason)}")
    {:fatal, fatal_reason, state}
  end

  defp reload_restored_state(original_state, replacement_state) do
    {profiles, path_ids, revisions} = load_profiles(original_state.profile_dir)

    if profiles == original_state.profiles and revisions == original_state.revisions do
      history = load_history(original_state.profile_dir)
      active_revisions = load_active_revisions(original_state.profile_dir, profiles, history)

      {:ok,
       %{
         replacement_state
         | profiles: profiles,
           revisions: revisions,
           history: history,
           active_revisions: active_revisions,
           path_ids: path_ids,
           pending_reloads: MapSet.new()
       }}
    else
      {:error, :namespace_mismatch}
    end
  end

  defp publish_replacement_events(profiles, omitted_ids) do
    Enum.each(profiles, fn profile ->
      EventBus.publish("netman:profile:changed", {:updated, profile.id})
    end)

    Enum.each(omitted_ids, fn id ->
      EventBus.publish("netman:profile:changed", {:deleted, id})
    end)
  end

  defp validate_replacement_profiles(profiles) when is_list(profiles) do
    with true <- Enum.all?(profiles, &match?(%Profile{}, &1)),
         ids = Enum.map(profiles, & &1.id),
         true <- length(ids) == length(Enum.uniq(ids)),
         {:ok, validated} <- prepare_replacement_profiles(profiles) do
      {:ok, validated}
    else
      false -> {:error, :invalid_profiles}
      {:error, _reason} = error -> error
    end
  end

  defp validate_replacement_profiles(_profiles), do: {:error, :invalid_profiles}

  defp prepare_replacement_profiles(profiles) do
    Enum.reduce_while(profiles, {:ok, []}, fn profile, {:ok, validated} ->
      case prepare_profile(profile.id, profile) do
        {:ok, profile, _contents, _revision} -> {:cont, {:ok, [profile | validated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      {:error, _reason} = error -> error
    end
  end

  defp check_namespace_revision(state, opts) do
    case Keyword.fetch(opts, :expected_revision) do
      :error ->
        :ok

      {:ok, expected_revision} when is_binary(expected_revision) ->
        current_revision = namespace_revision_for(state.revisions)

        if expected_revision == current_revision,
          do: :ok,
          else: {:error, {:conflict, current_revision}}

      {:ok, :missing} ->
        {:error, :invalid_revision}
    end
  end

  defp put_replacement_profiles(state, profiles) do
    Enum.reduce_while(profiles, {:ok, state}, fn profile, {:ok, state} ->
      case put_state(state, profile.id, profile, [], false) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason, state} -> {:halt, {:error, reason, state}}
      end
    end)
  end

  defp delete_replacement_profiles(state, ids) do
    Enum.reduce_while(ids, {:ok, state}, fn id, {:ok, state} ->
      case delete_state(state, id, [], false) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason, state} -> {:halt, {:error, reason, state}}
      end
    end)
  end

  defp mark_active_state(state, id, revision) do
    with :ok <- valid_filename_id(id),
         :ok <- valid_revision(revision),
         {:ok, desired_revision} <- Map.fetch(state.revisions, id),
         true <- desired_revision == revision,
         {:ok, entries} <- Map.fetch(state.history, id),
         {:ok, entry} <- Map.fetch(entries, revision) do
      activated_at = now(state)
      active = %{revision: revision, activated_at: activated_at}
      entry = %{entry | activated_at: activated_at}

      with :ok <- persist_history_metadata(state, entry),
           :ok <-
             durable_write(
               active_path(state.profile_dir, id),
               encode_active(id, active),
               state.file_ops
             ) do
        entries = Map.put(entries, revision, entry)

        state = %{
          state
          | history: Map.put(state.history, id, entries),
            active_revisions: Map.put(state.active_revisions, id, active)
        }

        {:ok, state}
      else
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :not_found}
      false -> {:error, {:conflict, Map.get(state.revisions, id)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_revision(revision)
       when is_binary(revision) and byte_size(revision) == 64 do
    if String.match?(revision, ~r/\A[0-9a-f]{64}\z/),
      do: :ok,
      else: {:error, :invalid_revision}
  end

  defp valid_revision(_revision), do: {:error, :invalid_revision}

  defp revision_for_contents(contents) do
    :crypto.hash(:sha256, contents)
    |> Base.encode16(case: :lower)
  end

  defp profile_path(profile_dir, id), do: Path.join(profile_dir, "#{id}.toml")

  defp history_root(profile_dir), do: Path.join(profile_dir, @history_directory)

  defp history_profile_dir(profile_dir, id),
    do: Path.join(history_root(profile_dir), id)

  defp history_snapshot_path(profile_dir, id, revision),
    do: Path.join(history_profile_dir(profile_dir, id), "#{revision}.toml")

  defp history_metadata_path(profile_dir, id, revision),
    do: Path.join(history_profile_dir(profile_dir, id), "#{revision}.json")

  defp active_root(profile_dir), do: Path.join(profile_dir, @active_directory)
  defp active_path(profile_dir, id), do: Path.join(active_root(profile_dir), "#{id}.json")

  defp replacement_journal_path(profile_dir),
    do: Path.join(profile_dir, @replacement_journal)

  defp persist_replacement_journal(state, replacement_profiles) do
    journal = %{
      profile_dir: state.profile_dir,
      profiles: state.profiles,
      active_revisions: state.active_revisions,
      replacement_ids: Enum.map(replacement_profiles, & &1.id)
    }

    contents =
      Jason.encode!(%{
        "version" => 1,
        "profiles" =>
          state.revisions
          |> Enum.sort()
          |> Enum.map(fn {id, revision} ->
            %{"profile_id" => id, "revision" => revision}
          end),
        "active_revisions" =>
          state.active_revisions
          |> Enum.sort()
          |> Enum.map(fn {id, active} ->
            %{
              "profile_id" => id,
              "revision" => active.revision,
              "activated_at" => DateTime.to_iso8601(active.activated_at)
            }
          end),
        "replacement_ids" => Enum.sort(journal.replacement_ids)
      })

    case durable_write(replacement_journal_path(state.profile_dir), contents, state.file_ops) do
      :ok -> {:ok, journal}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover_pending_replacement(profile_dir, file_ops) do
    case load_replacement_journal(profile_dir) do
      {:ok, nil} ->
        :ok

      {:ok, journal} ->
        case restore_replacement(journal, file_ops) do
          :ok -> :ok
          {:error, reason} -> {:error, {:replacement_recovery_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:replacement_recovery_failed, reason}}
    end
  end

  defp load_replacement_journal(profile_dir) do
    path = replacement_journal_path(profile_dir)

    case read_regular_file(path) do
      {:ok, contents} -> decode_replacement_journal(profile_dir, contents)
      {:error, {:file_read, :enoent}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_replacement_journal(profile_dir, contents) do
    with {:ok,
          %{
            "version" => 1,
            "profiles" => profile_refs,
            "active_revisions" => active_refs,
            "replacement_ids" => replacement_ids
          }} <- Jason.decode(contents),
         {:ok, profiles, _revisions} <- decode_replacement_profiles(profile_dir, profile_refs),
         {:ok, active_revisions} <-
           decode_replacement_active(profile_dir, active_refs, profiles),
         {:ok, replacement_ids} <- decode_replacement_ids(replacement_ids) do
      {:ok,
       %{
         profile_dir: profile_dir,
         profiles: profiles,
         active_revisions: active_revisions,
         replacement_ids: replacement_ids
       }}
    else
      _reason -> {:error, :invalid_replacement_journal}
    end
  end

  defp decode_replacement_profiles(profile_dir, refs) when is_list(refs) do
    refs
    |> Enum.reduce_while({:ok, %{}, %{}}, fn
      %{"profile_id" => id, "revision" => revision}, {:ok, profiles, revisions} ->
        with :ok <- valid_filename_id(id),
             :ok <- valid_revision(revision),
             false <- Map.has_key?(profiles, id),
             {:ok, %Profile{id: ^id} = profile} <-
               parse_toml_file(history_snapshot_path(profile_dir, id, revision)),
             true <- profile_revision(profile) == revision do
          {:cont, {:ok, Map.put(profiles, id, profile), Map.put(revisions, id, revision)}}
        else
          _reason -> {:halt, {:error, :invalid_replacement_journal}}
        end

      _ref, _acc ->
        {:halt, {:error, :invalid_replacement_journal}}
    end)
  end

  defp decode_replacement_profiles(_profile_dir, _refs),
    do: {:error, :invalid_replacement_journal}

  defp decode_replacement_active(profile_dir, refs, profiles) when is_list(refs) do
    refs
    |> Enum.reduce_while({:ok, %{}}, fn
      %{"profile_id" => id, "revision" => revision, "activated_at" => activated_at},
      {:ok, active_revisions} ->
        with :ok <- valid_filename_id(id),
             :ok <- valid_revision(revision),
             true <- Map.has_key?(profiles, id),
             false <- Map.has_key?(active_revisions, id),
             %DateTime{} = activated_at <- parse_datetime(activated_at),
             {:ok, %Profile{id: ^id} = profile} <-
               parse_toml_file(history_snapshot_path(profile_dir, id, revision)),
             true <- profile_revision(profile) == revision do
          active = %{revision: revision, activated_at: activated_at}
          {:cont, {:ok, Map.put(active_revisions, id, active)}}
        else
          _reason -> {:halt, {:error, :invalid_replacement_journal}}
        end

      _ref, _acc ->
        {:halt, {:error, :invalid_replacement_journal}}
    end)
  end

  defp decode_replacement_active(_profile_dir, _refs, _profiles),
    do: {:error, :invalid_replacement_journal}

  defp decode_replacement_ids(ids) when is_list(ids) do
    if Enum.all?(ids, &(is_binary(&1) and valid_filename_id(&1) == :ok)) and
         length(ids) == length(Enum.uniq(ids)) do
      {:ok, ids}
    else
      {:error, :invalid_replacement_journal}
    end
  end

  defp decode_replacement_ids(_ids), do: {:error, :invalid_replacement_journal}

  defp restore_replacement(journal, file_ops) do
    original_ids = Map.keys(journal.profiles)
    added_ids = journal.replacement_ids -- original_ids
    touched_ids = Enum.uniq(original_ids ++ journal.replacement_ids) |> Enum.sort()

    with :ok <- restore_replacement_profiles(journal, file_ops),
         :ok <- delete_replacement_additions(journal.profile_dir, added_ids, file_ops),
         :ok <- delete_replacement_active(journal.profile_dir, touched_ids, file_ops),
         :ok <- restore_replacement_active(journal, file_ops),
         :ok <- durable_delete(replacement_journal_path(journal.profile_dir), file_ops) do
      :ok
    end
  end

  defp restore_replacement_profiles(journal, file_ops) do
    journal.profiles
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {id, profile}, :ok ->
      case durable_write(
             profile_path(journal.profile_dir, id),
             Profile.canonical_toml(profile),
             file_ops
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp delete_replacement_additions(profile_dir, ids, file_ops) do
    ids
    |> Enum.map(&profile_path(profile_dir, &1))
    |> durable_delete_all(file_ops)
  end

  defp delete_replacement_active(profile_dir, ids, file_ops) do
    ids
    |> Enum.map(&active_path(profile_dir, &1))
    |> durable_delete_all(file_ops)
  end

  defp restore_replacement_active(journal, file_ops) do
    journal.active_revisions
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {id, active}, :ok ->
      case durable_write(
             active_path(journal.profile_dir, id),
             encode_active(id, active),
             file_ops
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_current_history(history, profiles, revisions, profile_dir, file_ops, clock) do
    Enum.reduce_while(profiles, {:ok, history}, fn {id, profile}, {:ok, history} ->
      revision = Map.fetch!(revisions, id)

      if get_in(history, [id, revision]) do
        {:cont, {:ok, history}}
      else
        stored_at = safe_now(clock)

        entry = %{
          profile_id: id,
          revision: revision,
          profile: profile,
          stored_at: stored_at,
          activated_at: nil
        }

        case persist_history_entry(profile_dir, file_ops, entry) do
          :ok -> {:cont, {:ok, put_history_entry(history, entry)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp ensure_history_entry(state, profile, revision) do
    case get_in(state.history, [profile.id, revision]) do
      nil ->
        entry = %{
          profile_id: profile.id,
          revision: revision,
          profile: profile,
          stored_at: now(state),
          activated_at: nil
        }

        case persist_history_entry(state.profile_dir, state.file_ops, entry) do
          :ok -> {:ok, %{state | history: put_history_entry(state.history, entry)}}
          {:error, reason} -> {:error, reason}
        end

      _entry ->
        {:ok, state}
    end
  end

  defp put_history_entry(history, entry) do
    Map.update(history, entry.profile_id, %{entry.revision => entry}, fn entries ->
      Map.put(entries, entry.revision, entry)
    end)
  end

  defp persist_history_entry(profile_dir, file_ops, entry) do
    snapshot_path = history_snapshot_path(profile_dir, entry.profile_id, entry.revision)
    contents = Profile.canonical_toml(entry.profile)

    result =
      with :ok <- persist_immutable_snapshot(snapshot_path, contents, entry.revision, file_ops),
           :ok <-
             durable_write(
               history_metadata_path(profile_dir, entry.profile_id, entry.revision),
               encode_history_metadata(entry),
               file_ops
             ) do
        :ok
      end

    result
  end

  defp persist_history_metadata(state, entry) do
    durable_write(
      history_metadata_path(state.profile_dir, entry.profile_id, entry.revision),
      encode_history_metadata(entry),
      state.file_ops
    )
  end

  defp persist_immutable_snapshot(path, contents, revision, file_ops) do
    case File.lstat(path) do
      {:error, :enoent} ->
        durable_write(path, contents, file_ops)

      {:ok, %{type: :regular}} ->
        with {:ok, existing} <- read_regular_file(path),
             true <- revision_for_contents(existing) == revision,
             true <- existing == contents do
          :ok
        else
          _ -> {:error, {:history_snapshot_conflict, path}}
        end

      _other ->
        {:error, {:history_snapshot_conflict, path}}
    end
  end

  defp load_history(profile_dir) do
    profile_dir
    |> history_root()
    |> Path.join("*/*.toml")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn path, history ->
      id = path |> Path.dirname() |> Path.basename()
      revision = Path.basename(path, ".toml")

      with :ok <- valid_filename_id(id),
           :ok <- valid_revision(revision),
           {:ok, %Profile{id: ^id} = profile} <- parse_toml_file(path),
           true <- profile_revision(profile) == revision do
        entry = load_history_entry(profile_dir, path, id, revision, profile)
        put_history_entry(history, entry)
      else
        _reason ->
          Logger.warning("Ignoring invalid profile history snapshot #{path}")
          history
      end
    end)
  end

  defp load_history_entry(profile_dir, snapshot_path, id, revision, profile) do
    default_stored_at = file_timestamp(snapshot_path)

    metadata =
      profile_dir
      |> history_metadata_path(id, revision)
      |> read_json_file()

    metadata =
      if Map.get(metadata, "profile_id") == id and Map.get(metadata, "revision") == revision,
        do: metadata,
        else: %{}

    %{
      profile_id: id,
      revision: revision,
      profile: profile,
      stored_at: parse_datetime(Map.get(metadata, "stored_at")) || default_stored_at,
      activated_at: parse_datetime(Map.get(metadata, "activated_at"))
    }
  end

  defp load_active_revisions(profile_dir, profiles, history) do
    profile_dir
    |> active_root()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn path, active_revisions ->
      id = Path.basename(path, ".json")
      active = read_json_file(path)
      revision = Map.get(active, "revision")
      activated_at = parse_datetime(Map.get(active, "activated_at"))

      with :ok <- valid_filename_id(id),
           true <- Map.get(active, "profile_id") == id,
           :ok <- valid_revision(revision),
           true <- Map.has_key?(profiles, id),
           true <- not is_nil(get_in(history, [id, revision])),
           %DateTime{} <- activated_at do
        Map.put(active_revisions, id, %{revision: revision, activated_at: activated_at})
      else
        _reason ->
          Logger.warning("Ignoring invalid active profile pointer #{path}")
          active_revisions
      end
    end)
  end

  defp encode_history_metadata(entry) do
    Jason.encode!(%{
      "profile_id" => entry.profile_id,
      "revision" => entry.revision,
      "stored_at" => DateTime.to_iso8601(entry.stored_at),
      "activated_at" => encode_datetime(entry.activated_at)
    })
  end

  defp encode_active(id, active) do
    Jason.encode!(%{
      "profile_id" => id,
      "revision" => active.revision,
      "activated_at" => DateTime.to_iso8601(active.activated_at)
    })
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp read_json_file(path) do
    with {:ok, contents} <- read_regular_file(path),
         {:ok, value} when is_map(value) <- Jason.decode(contents) do
      value
    else
      _ -> %{}
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp file_timestamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: timestamp}} -> DateTime.from_unix!(timestamp)
      _ -> DateTime.from_unix!(0)
    end
  end

  defp now(state), do: safe_now(state.clock)

  defp safe_now(clock) do
    case clock.() do
      %DateTime{utc_offset: 0, std_offset: 0} = datetime ->
        DateTime.truncate(datetime, :microsecond)

      _ ->
        DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp clear_stale_active(state, id) do
    best_effort_delete_active_pointer(state, id)
    %{state | active_revisions: Map.delete(state.active_revisions, id)}
  end

  defp best_effort_delete_active_pointer(state, id) do
    case durable_delete(active_path(state.profile_dir, id), state.file_ops) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to remove active profile pointer: #{inspect(reason)}")
    end
  end

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

  defp lifecycle_metadata_path?(path, profile_dir) do
    expanded_path = Path.expand(path)

    Enum.any?([history_root(profile_dir), active_root(profile_dir)], fn root ->
      expanded_root = Path.expand(root)
      expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
    end)
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
    with {:ok, content} <- read_regular_file(path) do
      case Toml.decode(content) do
        {:ok, toml} -> Profile.from_toml(toml)
        {:error, reason} -> {:error, {:toml_parse, reason}}
      end
    end
  end

  defp read_regular_file(path) do
    with {:ok, path_info} <- profile_file_info(path),
         {:ok, device} <- open_profile_file(path) do
      try do
        with {:ok, device_info} <- open_file_info(device),
             :ok <- same_file(path_info, device_info),
             {:ok, current_path_info} <- profile_file_info(path),
             :ok <- same_file(current_path_info, device_info),
             {:ok, content} <- read_profile_file(device, 0, []) do
          {:ok, content}
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
          best_effort_delete_active_pointer(state, id)

          path_ids =
            path_ids
            |> Enum.reject(fn {_other_path, profile_id} -> profile_id == id end)
            |> Map.new()

          %{
            state
            | profiles: Map.delete(state.profiles, id),
              revisions: Map.delete(state.revisions, id),
              active_revisions: Map.delete(state.active_revisions, id),
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
      case ensure_history_entry(state, profile, revision) do
        {:ok, state} ->
          apply_durable_reload(state, path, profile, revision, old_id)

        {:error, reason} ->
          Logger.warning("Failed to persist reloaded profile history: #{inspect(reason)}")
          state
      end
    end
  end

  defp apply_durable_reload(state, path, profile, revision, old_id) do
    {profiles, revisions} =
      if old_id && old_id != profile.id do
        Logger.info("Profile ID changed from #{old_id} to #{profile.id} in #{path}")
        EventBus.publish("netman:profile:changed", {:deleted, old_id})
        best_effort_delete_active_pointer(state, old_id)

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

    state =
      %{
        state
        | profiles: profiles,
          revisions: revisions,
          path_ids: path_ids,
          active_revisions:
            if(old_id && old_id != profile.id,
              do: Map.delete(state.active_revisions, old_id),
              else: state.active_revisions
            )
      }

    state
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
