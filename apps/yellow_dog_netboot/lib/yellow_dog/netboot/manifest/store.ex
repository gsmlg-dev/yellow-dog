defmodule YellowDog.Netboot.Manifest.Store do
  @moduledoc """
  Boot profile and install manifest configuration store.

  Uses Store.Ets for profile storage. Loads profiles from TOML configuration
  and provides lookup APIs. Supports hot-reload without restart.
  """

  use GenServer
  use YellowDog.Data.Collection

  alias YellowDog.Data.Store
  alias YellowDog.Netboot.Boot.Profile

  defcollection(:netboot_profiles,
    key_field: :id,
    adapter: YellowDog.Data.Store.Ets
  )

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get a boot profile by ID."
  @spec get_profile(String.t()) :: {:ok, Profile.t()} | {:error, :not_found}
  def get_profile(id) do
    Store.get(store_state(), id)
  end

  @doc "List all boot profiles."
  @spec list_profiles() :: [Profile.t()]
  def list_profiles do
    {:ok, profiles} = Store.list(store_state())
    profiles
  end

  @doc "Get install manifest for a profile."
  @spec get_manifest(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_manifest(profile_id) do
    case get_profile(profile_id) do
      {:ok, %{manifest: manifest}} when map_size(manifest) > 0 -> {:ok, manifest}
      {:ok, _} -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Get the default profile ID."
  @spec default_profile_id() :: String.t() | nil
  def default_profile_id do
    :persistent_term.get({__MODULE__, :default_profile}, nil)
  end

  @doc "Hot-reload profiles from config."
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "Add or update a profile."
  @spec put_profile(Profile.t()) :: :ok
  def put_profile(%Profile{id: id} = profile) do
    GenServer.call(__MODULE__, {:put_profile, id, profile})
  end

  @doc "Delete a profile."
  @spec delete_profile(String.t()) :: :ok
  def delete_profile(id) do
    GenServer.call(__MODULE__, {:delete_profile, id})
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
    load_config(store, config)
    {:ok, %{store: store, config: config}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {:ok, store} = Store.clear(state.store)
    :persistent_term.put({__MODULE__, :store}, store)
    load_config(store, state.config)
    {:reply, :ok, %{state | store: store}}
  end

  @impl true
  def handle_call({:put_profile, id, profile}, _from, state) do
    {:ok, store} = Store.put(state.store, id, profile)
    :persistent_term.put({__MODULE__, :store}, store)
    {:reply, :ok, %{state | store: store}}
  end

  @impl true
  def handle_call({:delete_profile, id}, _from, state) do
    {:ok, store} = Store.delete(state.store, id)
    :persistent_term.put({__MODULE__, :store}, store)
    {:reply, :ok, %{state | store: store}}
  end

  @impl true
  def handle_call({:set_default_profile, id}, _from, state) do
    :persistent_term.put({__MODULE__, :default_profile}, id)
    {:reply, :ok, state}
  end

  # --- Private ---

  defp store_state do
    :persistent_term.get({__MODULE__, :store})
  end

  defp load_config(store, config) do
    default_profile = get_nested(config, ["default_profile"])

    if default_profile do
      :persistent_term.put({__MODULE__, :default_profile}, default_profile)
    end

    profiles = get_nested(config, ["profiles"]) || %{}

    Enum.each(profiles, fn {id, profile_config} ->
      profile = Profile.from_config(id, profile_config)
      Store.put(store, id, profile)
    end)
  end

  defp get_nested(value, []), do: value
  defp get_nested(nil, _), do: nil

  defp get_nested(map, [key | rest]) when is_map(map) do
    get_nested(Map.get(map, key), rest)
  end

  defp get_nested(_, _), do: nil
end
