defmodule YellowDog.Netboot.Manifest.Store do
  @moduledoc """
  Boot profile and install manifest configuration store.

  Configured runtime profiles and managed control profiles are held separately.
  The visible ETS collection gives managed profiles precedence without changing
  the configured profile representation.
  """

  use GenServer
  use YellowDog.Data.Collection

  alias YellowDog.Data.Store
  alias YellowDog.Netboot.Boot.Profile
  alias YellowDog.Netboot.ManagedStorage.AtomicJson
  alias YellowDog.Netboot.Manifest.ManagedProfile

  @managed_version 1
  @empty_snapshot %{"version" => @managed_version, "profiles" => []}

  defcollection(:netboot_profiles,
    key_field: :id,
    adapter: YellowDog.Data.Store.Ets
  )

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get a configured or managed boot profile by ID."
  @spec get_profile(String.t()) :: {:ok, Profile.t() | ManagedProfile.t()} | {:error, :not_found}
  def get_profile(id) do
    Store.get(store_state(), id)
  end

  @doc "List configured and managed profiles, with managed IDs taking precedence."
  @spec list_profiles() :: [Profile.t() | ManagedProfile.t()]
  def list_profiles do
    {:ok, profiles} = Store.list(store_state())
    profiles
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
          :ok | {:error, {:managed_sidecar_invalid, term()} | {:activation_failed, term()}}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "Add or update a legacy configured runtime profile."
  @spec put_profile(Profile.t()) :: :ok | {:error, {:activation_failed, term()}}
  def put_profile(%Profile{id: id} = profile) do
    GenServer.call(__MODULE__, {:put_profile, id, profile})
  end

  @doc "Delete a legacy configured runtime profile."
  @spec delete_profile(String.t()) :: :ok | {:error, {:activation_failed, term()}}
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
          {:ok, %{previous: map(), current: map()}}
          | {:error,
             {:persist_failed, AtomicJson.error()}
             | {:activation_failed, term()}
             | {:rollback_failed, term(), AtomicJson.error()}}
  def put_managed_profile(%ManagedProfile{} = profile) do
    GenServer.call(__MODULE__, {:put_managed_profile, profile})
  end

  @doc "Delete a managed profile and reveal its configured fallback, if any."
  @spec delete_managed_profile(String.t()) ::
          {:ok, %{previous: map(), current: map()}}
          | {:error,
             {:persist_failed, AtomicJson.error()}
             | {:activation_failed, term()}
             | {:rollback_failed, term(), AtomicJson.error()}}
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

    case activate(state, state.managed_profiles, configured_profiles) do
      {:ok, store} ->
        {:reply, :ok, %{state | configured_profiles: configured_profiles, store: store}}

      {:error, reason} ->
        {:reply, {:error, {:activation_failed, reason}}, state}
    end
  end

  @impl true
  def handle_call({:delete_profile, id}, _from, state) do
    configured_profiles = Map.delete(state.configured_profiles, id)

    case activate(state, state.managed_profiles, configured_profiles) do
      {:ok, store} ->
        {:reply, :ok, %{state | configured_profiles: configured_profiles, store: store}}

      {:error, reason} ->
        {:reply, {:error, {:activation_failed, reason}}, state}
    end
  end

  @impl true
  def handle_call(:managed_snapshot, _from, state) do
    {:reply, {:ok, snapshot(state.managed_profiles)}, state}
  end

  @impl true
  def handle_call({:put_managed_profile, profile}, _from, state) do
    managed_profiles = Map.put(state.managed_profiles, profile.profile_id, profile)

    case persist_and_activate(state, managed_profiles) do
      {:ok, snapshot, store} ->
        {:reply, {:ok, snapshot}, %{state | managed_profiles: managed_profiles, store: store}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_managed_profile, profile_id}, _from, state) do
    managed_profiles = Map.delete(state.managed_profiles, profile_id)

    case persist_and_activate(state, managed_profiles) do
      {:ok, snapshot, store} ->
        {:reply, {:ok, snapshot}, %{state | managed_profiles: managed_profiles, store: store}}

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
    with {:ok, managed_profiles} <- load_managed_profiles(state),
         {:ok, store} <- activate(state, managed_profiles, configured_profiles(state.config)) do
      maybe_set_default_profile(state.config)

      {:ok,
       %{
         state
         | store: store,
           managed_profiles: managed_profiles,
           configured_profiles: configured_profiles(state.config)
       }}
    else
      {:error, {:managed_sidecar_invalid, _reason} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:activation_failed, reason}}
    end
  end

  defp persist_and_activate(state, managed_profiles) do
    previous_snapshot = snapshot(state.managed_profiles)
    current_snapshot = snapshot(managed_profiles)

    case AtomicJson.write(
           state.managed_profiles_path,
           current_snapshot,
           state.managed_storage_opts
         ) do
      :ok ->
        case activate(state, managed_profiles, state.configured_profiles) do
          {:ok, store} ->
            {:ok, %{previous: previous_snapshot, current: current_snapshot}, store}

          {:error, activation_reason} ->
            rollback(state, previous_snapshot, activation_reason)
        end

      {:error, reason} ->
        {:error, {:persist_failed, reason}}
    end
  end

  defp rollback(state, previous_snapshot, activation_reason) do
    case AtomicJson.write(
           state.managed_profiles_path,
           previous_snapshot,
           state.managed_storage_opts
         ) do
      :ok ->
        case activate(state, state.managed_profiles, state.configured_profiles) do
          {:ok, _store} ->
            {:error, {:activation_failed, activation_reason}}

          {:error, restore_reason} ->
            {:error, {:rollback_failed, activation_reason, restore_reason}}
        end

      {:error, rollback_reason} ->
        {:error, {:rollback_failed, activation_reason, rollback_reason}}
    end
  end

  defp activate(state, managed_profiles, configured_profiles) do
    profiles = Map.merge(configured_profiles, managed_profiles)

    with :ok <- state.managed_activation.(profiles),
         {:ok, store} <- replace_profiles(state.store, profiles) do
      :persistent_term.put({__MODULE__, :store}, store)
      {:ok, store}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :activation_failed}
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
