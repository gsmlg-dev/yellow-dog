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

  defstruct [:profile_dir, :watcher_pid, profiles: %{}]

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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

  @doc "Store a profile."
  @spec put(String.t(), Profile.t()) :: :ok
  def put(id, %Profile{} = profile) do
    GenServer.call(__MODULE__, {:put, id, profile})
  end

  @doc "Delete a profile by ID."
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(id) do
    GenServer.call(__MODULE__, {:delete, id})
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
  def init(_opts) do
    profile_dir =
      Application.get_env(:yellow_dog_netman, :profile_dir, @default_profile_dir)

    profiles = load_profiles(profile_dir)
    watcher_pid = start_watcher(profile_dir)

    {:ok,
     %__MODULE__{
       profile_dir: profile_dir,
       watcher_pid: watcher_pid,
       profiles: profiles
     }}
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

  def handle_call({:put, id, profile}, _from, state) do
    profiles = Map.put(state.profiles, id, profile)
    EventBus.publish("netman:profile:changed", {:updated, id})
    {:reply, :ok, %{state | profiles: profiles}}
  end

  def handle_call({:delete, id}, _from, state) do
    if Map.has_key?(state.profiles, id) do
      profiles = Map.delete(state.profiles, id)
      EventBus.publish("netman:profile:changed", {:deleted, id})
      {:reply, :ok, %{state | profiles: profiles}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:import_file, path}, _from, state) do
    if valid_profile_path?(path) do
      case parse_toml_file(path) do
        {:ok, profile} ->
          profiles = Map.put(state.profiles, profile.id, profile)
          EventBus.publish("netman:profile:changed", {:added, profile.id})
          {:reply, {:ok, profile}, %{state | profiles: profiles}}

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

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    if Path.extname(path) == ".toml" and :modified in events and not symlink?(path) do
      Logger.info("Profile file changed: #{path}")
      state = reload_profile(state, path)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("Profile directory watcher stopped")
    {:noreply, %{state | watcher_pid: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Internal

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
      dir
      |> Path.join("*.toml")
      |> Path.wildcard()
      |> Enum.reject(&symlink?/1)
      |> Enum.reduce(%{}, fn path, acc ->
        case parse_toml_file(path) do
          {:ok, profile} ->
            Map.put(acc, profile.id, profile)

          {:error, reason} ->
            Logger.warning("Failed to parse profile #{path}: #{inspect(reason)}")
            acc
        end
      end)
    else
      Logger.info("Profile directory does not exist: #{dir}")
      %{}
    end
  end

  defp parse_toml_file(path) do
    # Use lstat (not stat) to detect symlinks atomically with size check
    with {:ok, %{type: :regular, size: size}} when size <= @max_profile_file_bytes <-
           File.lstat(path),
         {:ok, content} <- File.read(path) do
      case Toml.decode(content) do
        {:ok, toml} -> Profile.from_toml(toml)
        {:error, reason} -> {:error, {:toml_parse, reason}}
      end
    else
      {:ok, %{type: :symlink}} ->
        {:error, {:symlink_rejected, path}}

      {:ok, %{size: size}} ->
        {:error, {:file_too_large, size, @max_profile_file_bytes}}

      {:ok, %{type: type}} ->
        {:error, {:not_regular_file, type}}

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

  defp reload_profile(state, path) do
    case parse_toml_file(path) do
      {:ok, profile} ->
        profiles = Map.put(state.profiles, profile.id, profile)
        EventBus.publish("netman:profile:changed", {:reloaded, profile.id})
        %{state | profiles: profiles}

      {:error, reason} ->
        Logger.warning("Failed to reload profile #{path}: #{inspect(reason)}")
        state
    end
  end
end
