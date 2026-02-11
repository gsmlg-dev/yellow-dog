defmodule YellowDog.Netboot.Manifest.Store do
  @moduledoc """
  Boot profile and install manifest configuration store.

  Loads profiles from TOML configuration and provides lookup APIs.
  Supports hot-reload without restart.
  """

  use GenServer

  alias YellowDog.Netboot.Boot.Profile

  @table __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get a boot profile by ID."
  @spec get_profile(String.t()) :: {:ok, Profile.t()} | {:error, :not_found}
  def get_profile(id) do
    case :ets.lookup(@table, {:profile, id}) do
      [{_, profile}] -> {:ok, profile}
      [] -> {:error, :not_found}
    end
  end

  @doc "List all boot profiles."
  @spec list_profiles() :: [Profile.t()]
  def list_profiles do
    :ets.match_object(@table, {{:profile, :_}, :_})
    |> Enum.map(fn {_, profile} -> profile end)
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
    case :ets.lookup(@table, :default_profile) do
      [{_, id}] -> id
      [] -> nil
    end
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

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    config = Keyword.get(opts, :config, %{})
    load_config(config)
    {:ok, %{config: config}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    load_config(state.config)
    {:reply, :ok, state}
  end

  def handle_call({:put_profile, id, profile}, _from, state) do
    :ets.insert(@table, {{:profile, id}, profile})
    {:reply, :ok, state}
  end

  def handle_call({:delete_profile, id}, _from, state) do
    :ets.delete(@table, {:profile, id})
    {:reply, :ok, state}
  end

  # --- Private ---

  defp load_config(config) do
    default_profile = get_nested(config, ["default_profile"])

    if default_profile do
      :ets.insert(@table, {:default_profile, default_profile})
    end

    profiles = get_nested(config, ["profiles"]) || %{}

    Enum.each(profiles, fn {id, profile_config} ->
      profile = Profile.from_config(id, profile_config)
      :ets.insert(@table, {{:profile, id}, profile})
    end)
  end

  defp get_nested(map, []) when is_map(map), do: map
  defp get_nested(nil, _), do: nil

  defp get_nested(map, [key | rest]) when is_map(map) do
    get_nested(Map.get(map, key), rest)
  end

  defp get_nested(_, _), do: nil
end
