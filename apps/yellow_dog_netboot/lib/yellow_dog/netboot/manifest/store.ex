defmodule YellowDog.Netboot.Manifest.Store do
  @moduledoc """
  Boot profile and install manifest configuration store.

  Configured runtime profiles remain the only values exposed to boot callers.
  Managed control profiles are kept separately and take precedence only through
  the explicit control-facing lookup and list APIs.
  """

  use GenServer
  use YellowDog.Data.Collection

  alias YellowDog.Data.Store
  alias YellowDog.Netboot.Boot.Profile
  alias YellowDog.Netboot.ManagedStorage.AtomicJson
  alias YellowDog.Netboot.Manifest.ManagedProfile

  @managed_version 1
  @default_max_bytes 1_048_576
  @empty_snapshot %{"version" => @managed_version, "profiles" => []}

  @type activation_reason ::
          :callback_error
          | :callback_exception
          | :callback_throw
          | :callback_exit
          | :visible_store_error
          | :visible_store_exception
          | :visible_store_throw
          | :visible_store_exit

  @type rollback_reason ::
          {:sidecar, AtomicJson.error()} | {:state, activation_reason()}

  @type managed_sidecar_reason ::
          AtomicJson.error()
          | :duplicate_profile_id
          | :invalid_profile
          | :invalid_snapshot

  @type mutation_error ::
          {:persist_failed, AtomicJson.error()}
          | {:activation_failed, activation_reason()}
          | {:rollback_failed, activation_reason(), rollback_reason()}

  defcollection(:netboot_profiles,
    key_field: :id,
    adapter: YellowDog.Data.Store.Ets
  )

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get a configured runtime boot profile by ID."
  @spec get_profile(String.t()) :: {:ok, Profile.t()} | {:error, :not_found}
  def get_profile(id) do
    Store.get(store_state(), id)
  end

  @doc "List configured runtime boot profiles."
  @spec list_profiles() :: [Profile.t()]
  def list_profiles do
    {:ok, profiles} = Store.list(store_state())
    profiles
  end

  @doc "Get a managed-first profile for control-plane use."
  @spec get_control_profile(String.t()) ::
          {:ok, ManagedProfile.t() | Profile.t()} | {:error, :not_found}
  def get_control_profile(id) do
    GenServer.call(__MODULE__, {:get_control_profile, id})
  end

  @doc "List managed-first profiles for control-plane use."
  @spec list_control_profiles() :: [ManagedProfile.t() | Profile.t()]
  def list_control_profiles do
    GenServer.call(__MODULE__, :list_control_profiles)
  end

  @doc "Get install manifest for a configured profile."
  @spec get_manifest(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_manifest(profile_id) do
    case get_profile(profile_id) do
      {:ok, %{manifest: manifest}} when map_size(manifest) > 0 -> {:ok, manifest}
      {:ok, _profile} -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Get the default profile ID."
  @spec default_profile_id() :: String.t() | nil
  def default_profile_id do
    :persistent_term.get({__MODULE__, :default_profile}, nil)
  end

  @doc "Hot-reload managed profiles and configured fallbacks."
  @spec reload() ::
          :ok
          | {:error,
             {:managed_sidecar_invalid, managed_sidecar_reason()}
             | {:activation_failed, activation_reason()}
             | {:rollback_failed, activation_reason(), {:state, activation_reason()}}}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "Add or update a legacy configured runtime profile."
  @spec put_profile(Profile.t()) ::
          :ok
          | {:error,
             {:activation_failed, activation_reason()}
             | {:rollback_failed, activation_reason(), {:state, activation_reason()}}}
  def put_profile(%Profile{id: id} = profile) do
    GenServer.call(__MODULE__, {:put_profile, id, profile})
  end

  @doc "Delete a legacy configured runtime profile."
  @spec delete_profile(String.t()) ::
          :ok
          | {:error,
             {:activation_failed, activation_reason()}
             | {:rollback_failed, activation_reason(), {:state, activation_reason()}}}
  def delete_profile(id) do
    GenServer.call(__MODULE__, {:delete_profile, id})
  end

  @doc "Return the versioned managed profile control snapshot."
  @spec managed_snapshot() :: {:ok, map()}
  def managed_snapshot do
    GenServer.call(__MODULE__, :managed_snapshot)
  end

  @doc "Persist and activate a managed wire-native profile."
  @spec put_managed_profile(ManagedProfile.t()) ::
          {:ok, %{previous: map(), current: map()}} | {:error, mutation_error()}
  def put_managed_profile(%ManagedProfile{} = profile) do
    GenServer.call(__MODULE__, {:put_managed_profile, profile})
  end

  @doc "Delete a managed profile and reveal its configured control fallback."
  @spec delete_managed_profile(String.t()) ::
          {:ok, %{previous: map(), current: map()}} | {:error, mutation_error()}
  def delete_managed_profile(profile_id) when is_binary(profile_id) do
    GenServer.call(__MODULE__, {:delete_managed_profile, profile_id})
  end

  @doc "Set the default profile ID."
  @spec set_default_profile(String.t()) :: :ok
  def set_default_profile(id) do
    GenServer.call(__MODULE__, {:set_default_profile, id})
  end

  @impl true
  def init(opts) do
    {:ok, store} = Store.init(collection(), [])
    :persistent_term.put({__MODULE__, :store}, store)

    config = Keyword.get(opts, :config, %{})

    state = %{
      store: store,
      config: config,
      configured_profiles: configured_profiles(config),
      managed_profiles_path: managed_profiles_path(opts, config),
      managed_storage_opts: managed_storage_opts(opts, config),
      managed_activation: managed_activation(opts, config),
      managed_visible_replacement: managed_visible_replacement(opts),
      managed_profiles: %{}
    }

    case reload_state(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case reload_state(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:put_profile, id, profile}, _from, state) do
    configured_profiles = Map.put(state.configured_profiles, id, profile)

    case activate_with_state_rollback(state, state.managed_profiles, configured_profiles) do
      {:ok, store} ->
        {:reply, :ok, %{state | configured_profiles: configured_profiles, store: store}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_profile, id}, _from, state) do
    configured_profiles = Map.delete(state.configured_profiles, id)

    case activate_with_state_rollback(state, state.managed_profiles, configured_profiles) do
      {:ok, store} ->
        {:reply, :ok, %{state | configured_profiles: configured_profiles, store: store}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_control_profile, id}, _from, state) do
    reply =
      case Map.fetch(control_profiles(state.managed_profiles, state.configured_profiles), id) do
        {:ok, profile} -> {:ok, profile}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:list_control_profiles, _from, state) do
    profiles =
      state.managed_profiles
      |> control_profiles(state.configured_profiles)
      |> Map.values()
      |> Enum.sort_by(&control_profile_id/1)

    {:reply, profiles, state}
  end

  @impl true
  def handle_call(:managed_snapshot, _from, state) do
    {:reply, {:ok, snapshot(state.managed_profiles)}, state}
  end

  @impl true
  def handle_call({:put_managed_profile, profile}, _from, state) do
    managed_profiles = Map.put(state.managed_profiles, profile.profile_id, profile)

    case persist_and_activate(state, managed_profiles) do
      {:ok, snapshots, store} ->
        {:reply, {:ok, snapshots}, %{state | managed_profiles: managed_profiles, store: store}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_managed_profile, profile_id}, _from, state) do
    managed_profiles = Map.delete(state.managed_profiles, profile_id)

    case persist_and_activate(state, managed_profiles) do
      {:ok, snapshots, store} ->
        {:reply, {:ok, snapshots}, %{state | managed_profiles: managed_profiles, store: store}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:set_default_profile, id}, _from, state) do
    :persistent_term.put({__MODULE__, :default_profile}, id)
    {:reply, :ok, state}
  end

  defp reload_state(state) do
    configured_profiles = configured_profiles(state.config)

    with {:ok, managed_profiles} <- load_managed_profiles(state),
         {:ok, store} <-
           activate_with_state_rollback(state, managed_profiles, configured_profiles) do
      maybe_set_default_profile(state.config)

      {:ok,
       %{
         state
         | store: store,
           managed_profiles: managed_profiles,
           configured_profiles: configured_profiles
       }}
    end
  end

  defp activate_with_state_rollback(state, managed_profiles, configured_profiles) do
    with {:ok, previous_visible} <- visible_profiles(state.store) do
      case activate(state, managed_profiles, configured_profiles) do
        {:ok, store} ->
          {:ok, store}

        {:error, activation_reason} ->
          case restore_visible(state.store, previous_visible) do
            {:ok, _store} ->
              {:error, {:activation_failed, activation_reason}}

            {:error, restore_reason} ->
              {:error, {:rollback_failed, activation_reason, {:state, restore_reason}}}
          end
      end
    else
      {:error, reason} -> {:error, {:activation_failed, reason}}
    end
  end

  defp persist_and_activate(state, managed_profiles) do
    previous_snapshot = snapshot(state.managed_profiles)
    current_snapshot = snapshot(managed_profiles)

    with :ok <- validate_candidate(current_snapshot, state.managed_storage_opts),
         {:ok, previous_visible} <- visible_profiles(state.store),
         :ok <-
           AtomicJson.write(
             state.managed_profiles_path,
             current_snapshot,
             state.managed_storage_opts
           ) do
      case activate(state, managed_profiles, state.configured_profiles) do
        {:ok, store} ->
          {:ok, %{previous: previous_snapshot, current: current_snapshot}, store}

        {:error, activation_reason} ->
          rollback(state, previous_snapshot, previous_visible, activation_reason)
      end
    else
      {:error, reason}
      when reason in [
             :callback_error,
             :callback_exception,
             :callback_throw,
             :callback_exit,
             :visible_store_error,
             :visible_store_exception,
             :visible_store_throw,
             :visible_store_exit
           ] ->
        {:error, {:activation_failed, reason}}

      {:error, reason} ->
        {:error, {:persist_failed, reason}}
    end
  end

  defp rollback(state, previous_snapshot, previous_visible, activation_reason) do
    case AtomicJson.write(
           state.managed_profiles_path,
           previous_snapshot,
           state.managed_storage_opts
         ) do
      :ok ->
        case restore_visible(state.store, previous_visible) do
          {:ok, _store} ->
            {:error, {:activation_failed, activation_reason}}

          {:error, restore_reason} ->
            {:error, {:rollback_failed, activation_reason, {:state, restore_reason}}}
        end

      {:error, rollback_reason} ->
        {:error, {:rollback_failed, activation_reason, {:sidecar, rollback_reason}}}
    end
  end

  defp activate(state, managed_profiles, configured_profiles) do
    with :ok <-
           safe_activation_callback(
             state.managed_activation,
             control_profiles(managed_profiles, configured_profiles)
           ),
         {:ok, store} <-
           safe_visible_replacement(
             state.managed_visible_replacement,
             state.store,
             configured_profiles
           ) do
      :persistent_term.put({__MODULE__, :store}, store)
      {:ok, store}
    end
  end

  defp safe_activation_callback(callback, profiles) when is_function(callback, 1) do
    try do
      case callback.(profiles) do
        :ok -> :ok
        _other -> {:error, :callback_error}
      end
    rescue
      _exception -> {:error, :callback_exception}
    catch
      :throw, _reason -> {:error, :callback_throw}
      :exit, _reason -> {:error, :callback_exit}
    end
  end

  defp safe_activation_callback(_callback, _profiles), do: {:error, :callback_error}

  defp safe_visible_replacement(replacement, store, profiles)
       when is_function(replacement, 2) do
    try do
      case replacement.(store, profiles) do
        {:ok, %{__adapter__: _adapter} = store} -> {:ok, store}
        _other -> {:error, :visible_store_error}
      end
    rescue
      _exception -> {:error, :visible_store_exception}
    catch
      :throw, _reason -> {:error, :visible_store_throw}
      :exit, _reason -> {:error, :visible_store_exit}
    end
  end

  defp safe_visible_replacement(_replacement, _store, _profiles),
    do: {:error, :visible_store_error}

  defp restore_visible(store, profiles) do
    safe_visible_replacement(&replace_profiles/2, store, profiles)
  end

  defp visible_profiles(store) do
    try do
      with {:ok, profiles} <- Store.list(store) do
        Enum.reduce_while(profiles, {:ok, %{}}, fn
          %Profile{id: id} = profile, {:ok, visible} when is_binary(id) ->
            {:cont, {:ok, Map.put(visible, id, profile)}}

          _profile, _visible ->
            {:halt, {:error, :visible_store_error}}
        end)
      else
        _other -> {:error, :visible_store_error}
      end
    rescue
      _exception -> {:error, :visible_store_exception}
    catch
      :throw, _reason -> {:error, :visible_store_throw}
      :exit, _reason -> {:error, :visible_store_exit}
    end
  end

  defp replace_profiles(store, profiles) do
    with {:ok, store} <- Store.clear(store) do
      Enum.reduce_while(profiles, {:ok, store}, fn {id, profile}, {:ok, store} ->
        case Store.put(store, id, profile) do
          {:ok, store} -> {:cont, {:ok, store}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp validate_candidate(snapshot, opts) do
    with {:ok, max_bytes} <- max_bytes(opts),
         {:ok, encoded} <- encode_snapshot(snapshot) do
      if byte_size(encoded) <= max_bytes, do: :ok, else: {:error, :too_large}
    end
  end

  defp max_bytes(opts) when is_list(opts) do
    case Keyword.get(opts, :max_bytes, @default_max_bytes) do
      size when is_integer(size) and size > 0 -> {:ok, size}
      _other -> {:error, :invalid_options}
    end
  end

  defp max_bytes(_opts), do: {:error, :invalid_options}

  defp encode_snapshot(snapshot) do
    case Jason.encode(snapshot) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :encode_failed}
    end
  rescue
    _exception -> {:error, :encode_failed}
  end

  defp load_managed_profiles(state) do
    case AtomicJson.read(state.managed_profiles_path, @empty_snapshot, state.managed_storage_opts) do
      {:ok, snapshot} -> decode_snapshot(snapshot)
      {:error, reason} -> {:error, {:managed_sidecar_invalid, reason}}
    end
  end

  defp decode_snapshot(%{"version" => @managed_version, "profiles" => profiles})
       when is_list(profiles) do
    profiles
    |> Enum.reduce_while({:ok, %{}}, fn wire, {:ok, managed_profiles} ->
      with {:ok, profile} <- ManagedProfile.from_wire(wire),
           false <- Map.has_key?(managed_profiles, profile.profile_id) do
        {:cont, {:ok, Map.put(managed_profiles, profile.profile_id, profile)}}
      else
        true -> {:halt, {:error, {:managed_sidecar_invalid, :duplicate_profile_id}}}
        {:error, _reason} -> {:halt, {:error, {:managed_sidecar_invalid, :invalid_profile}}}
      end
    end)
  end

  defp decode_snapshot(_snapshot), do: {:error, {:managed_sidecar_invalid, :invalid_snapshot}}

  defp snapshot(managed_profiles) do
    %{
      "version" => @managed_version,
      "profiles" =>
        managed_profiles
        |> Map.values()
        |> Enum.sort_by(& &1.profile_id)
        |> Enum.map(&ManagedProfile.to_wire/1)
    }
  end

  defp control_profiles(managed_profiles, configured_profiles) do
    Map.merge(configured_profiles, managed_profiles)
  end

  defp control_profile_id(%ManagedProfile{profile_id: id}), do: id
  defp control_profile_id(%Profile{id: id}), do: id

  defp configured_profiles(config) do
    config
    |> get_nested(["profiles"])
    |> Kernel.||(%{})
    |> Enum.reduce(%{}, fn {id, profile_config}, profiles ->
      Map.put(profiles, id, Profile.from_config(id, profile_config))
    end)
  end

  defp managed_profiles_path(opts, config) do
    Keyword.get(opts, :managed_profiles_path) ||
      get_nested(config, ["managed_profiles_path"]) ||
      Map.get(config, :managed_profiles_path) ||
      Path.join(YellowDog.Config.get_service_data_dir(:netboot), "managed_profiles.json")
  end

  defp managed_storage_opts(opts, config) do
    Keyword.get(opts, :managed_storage_opts) ||
      get_nested(config, ["managed_storage_opts"]) ||
      Map.get(config, :managed_storage_opts) || []
  end

  defp managed_activation(opts, config) do
    Keyword.get(opts, :managed_activation) ||
      get_nested(config, ["managed_activation"]) ||
      Map.get(config, :managed_activation) || fn _profiles -> :ok end
  end

  defp managed_visible_replacement(opts) do
    Keyword.get(opts, :managed_visible_replacement, &replace_profiles/2)
  end

  defp maybe_set_default_profile(config) do
    if default_profile = get_nested(config, ["default_profile"]) do
      :persistent_term.put({__MODULE__, :default_profile}, default_profile)
    end
  end

  defp store_state do
    :persistent_term.get({__MODULE__, :store})
  end

  defp get_nested(value, []), do: value
  defp get_nested(nil, _keys), do: nil

  defp get_nested(map, [key | rest]) when is_map(map) do
    get_nested(Map.get(map, key), rest)
  end

  defp get_nested(_value, _keys), do: nil
end
