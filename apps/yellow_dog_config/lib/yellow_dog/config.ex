defmodule YellowDog.Config do
  @moduledoc """
  Configuration management for YellowDog with TOML file support.

  Provides API for service applications to query their configuration
  and check if they are enabled.
  """

  use Agent

  @type config_map :: map()
  @type service_name :: :dns | :mdns | :dhcpv4 | :dhcpv6 | :netboot | :identity | :netman
  @type config_key :: atom()
  @type config_value :: term()
  @type zone_name :: String.t()
  @type zone_type :: :authoritative | :stub | :forward | :cache

  @state_tag :yellow_dog_config_state

  # Default configuration fallback (now defined in application)
  @default_config %{}

  @doc """
  Starts the configuration agent with the given config.
  """
  @spec start_link(config_map() | keyword()) :: Agent.on_start() | {:error, :invalid_config}
  def start_link(config) when is_map(config) do
    Agent.start_link(fn -> {@state_tag, config, config} end, name: __MODULE__)
  end

  def start_link(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         [:bootstrap, :effective] <- opts |> Keyword.keys() |> Enum.sort(),
         bootstrap when is_map(bootstrap) <- Keyword.get(opts, :bootstrap),
         effective when is_map(effective) <- Keyword.get(opts, :effective) do
      Agent.start_link(fn -> {@state_tag, bootstrap, effective} end, name: __MODULE__)
    else
      _invalid -> {:error, :invalid_config}
    end
  end

  def start_link(_config), do: {:error, :invalid_config}

  @doc """
  Gets all configuration as a map.
  """
  @spec get_all() :: config_map()
  def get_all do
    Agent.get(__MODULE__, &effective_config/1)
  end

  @doc """
  Gets the immutable local/bootstrap configuration captured at startup.

  Managed activation replaces only the effective configuration returned by
  `get_all/0`; the bootstrap baseline remains available for later activation
  and boot materialization.
  """
  @spec bootstrap() :: config_map()
  def bootstrap do
    Agent.get(__MODULE__, &bootstrap_config/1)
  end

  @doc """
  Atomically replaces the complete in-memory configuration.

  Returns a typed error instead of exiting when the configuration agent is not
  running. This is the activation primitive used by managed configuration.
  """
  @spec replace(config_map()) :: :ok | {:error, :invalid | :not_started}
  def replace(config) when is_map(config) do
    if Process.whereis(__MODULE__) do
      try do
        Agent.update(__MODULE__, &put_effective_config(&1, config))
      catch
        :exit, _reason -> {:error, :not_started}
      end
    else
      {:error, :not_started}
    end
  end

  def replace(_config), do: {:error, :invalid}

  @doc false
  @spec get_and_update_effective((config_map() -> {term(), config_map()})) :: term()
  def get_and_update_effective(function) when is_function(function, 1) do
    get_and_update_effective(function, 5_000)
  end

  @doc false
  @spec get_and_update_effective(
          (config_map() -> {term(), config_map()}),
          timeout()
        ) :: term()
  def get_and_update_effective(function, timeout)
      when is_function(function, 1) and
             (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) do
    Agent.get_and_update(
      __MODULE__,
      fn state ->
        {reply, config} = function.(effective_config(state))
        {reply, put_effective_config(state, config)}
      end,
      timeout
    )
  end

  @doc false
  @spec update_effective((config_map() -> config_map())) :: :ok
  def update_effective(function) when is_function(function, 1) do
    Agent.update(__MODULE__, fn state ->
      state
      |> effective_config()
      |> function.()
      |> then(&put_effective_config(state, &1))
    end)
  end

  @doc """
  Gets a configuration value by name.
  """
  @spec get(config_key()) :: config_value()
  def get(name) do
    Agent.get(__MODULE__, fn state -> state |> effective_config() |> Map.get(name) end)
  end

  @doc """
  Checks if a service is enabled in the configuration.

  ## Examples

      iex> YellowDog.Config.service_enabled?(:dns)
      true

      iex> YellowDog.Config.service_enabled?(:mdns)
      false
  """
  @spec service_enabled?(service_name()) :: boolean()
  def service_enabled?(service) do
    case get("core") do
      core_config when is_map(core_config) ->
        Map.get(core_config, to_string(service), default_service_enabled?(service))

      _ ->
        default_service_enabled?(service)
    end
  end

  @doc """
  Enables or disables a service in the configuration.

  ## Examples

      iex> YellowDog.Config.set_service_enabled(:dns, true)
      :ok

      iex> YellowDog.Config.set_service_enabled(:mdns, false)
      :ok
  """
  @spec set_service_enabled(service_name(), boolean()) :: :ok
  def set_service_enabled(service, enabled) do
    Agent.update(__MODULE__, fn state ->
      config = effective_config(state)
      core_config = Map.get(config, "core", %{})
      new_config = Map.put(config, "core", Map.put(core_config, to_string(service), enabled))
      put_effective_config(state, new_config)
    end)
  end

  @doc """
  Gets a specific configuration value for a service.

  ## Examples

      iex> YellowDog.Config.get(:dns, :port)
      53

      iex> YellowDog.Config.get(:dhcpv4, :listen)
      "0.0.0.0"
  """
  @spec get(service_name(), config_key()) :: config_value()
  def get(service, key) do
    service_config = get_service(service)
    Map.get(service_config, key, get_default_value(service, key))
  end

  @doc """
  Gets the entire configuration for a service.

  ## Examples

      iex> YellowDog.Config.get_service(:dns)
      %{listen: "0.0.0.0", port: 53}
  """
  @spec get_service(service_name()) :: map()
  def get_service(service) do
    case get(to_string(service)) do
      service_config when is_map(service_config) ->
        # Convert string keys to atoms for easier access
        # If keys are already atoms (from transformer), keep them as-is
        for {key, val} <- service_config, into: %{} do
          atom_key = if is_binary(key), do: safe_to_atom(key), else: key
          {atom_key, val}
        end

      _ ->
        get_default_service_config(service)
    end
  end

  @doc """
  Loads configuration from a TOML file path.

  ## Examples

      iex> YellowDog.Config.load("/path/to/config.toml")
      {:ok, %{...}}

      iex> YellowDog.Config.load("/nonexistent.toml")
      {:error, :enoent}
  """
  @spec load(String.t()) :: {:ok, config_map()} | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, config} ->
            :telemetry.execute(
              [:yellow_dog, :config, :loaded],
              %{count: 1},
              %{source: __MODULE__, path: path, severity: :info}
            )

            {:ok, config}

          {:error, reason} ->
            :telemetry.execute(
              [:yellow_dog, :config, :error],
              %{count: 1},
              %{
                source: __MODULE__,
                path: path,
                reason: :parse_error,
                error: inspect(reason),
                severity: :error
              }
            )

            {:error, reason}
        end

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :config, :error],
          %{count: 1},
          %{
            source: __MODULE__,
            path: path,
            reason: :read_error,
            error: inspect(reason),
            severity: :error
          }
        )

        {:error, reason}
    end
  end

  @doc """
  Loads configuration with fallback to defaults.
  """
  @spec load_with_fallback(String.t()) :: config_map()
  def load_with_fallback(path) do
    case load(path) do
      {:ok, config} ->
        config

      {:error, _reason} ->
        :telemetry.execute(
          [:yellow_dog, :config, :loaded],
          %{count: 1},
          %{source: __MODULE__, fallback: true, severity: :warning}
        )

        @default_config
    end
  end

  # Private helper functions

  defp effective_config({@state_tag, _bootstrap, effective}), do: effective
  defp effective_config(config), do: config

  defp bootstrap_config({@state_tag, bootstrap, _effective}), do: bootstrap
  defp bootstrap_config(config), do: config

  defp put_effective_config({@state_tag, bootstrap, _effective}, config),
    do: {@state_tag, bootstrap, config}

  defp put_effective_config(previous, config), do: {@state_tag, previous, config}

  defp default_service_enabled?(:netboot), do: false
  defp default_service_enabled?(_service), do: true

  defp get_default_service_config(service) do
    case Map.get(@default_config, to_string(service)) do
      nil ->
        %{}

      config ->
        for {key, val} <- config, into: %{}, do: {safe_to_atom(key), val}
    end
  end

  defp get_default_value(service, key) do
    service_config = get_default_service_config(service)
    Map.get(service_config, key)
  end

  defp safe_to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  @doc """
  Gets all DNS zones from configuration.

  ## Examples

      iex> YellowDog.Config.get_dns_zones()
      %{"example.com" => %{type: "authoritative", file: "zones/example.com.zone"}}
  """
  @spec get_dns_zones() :: map()
  def get_dns_zones do
    dns_config = get_service(:dns)
    Map.get(dns_config, :zones, %{})
  end

  @doc """
  Gets a specific DNS zone configuration.

  ## Examples

      iex> YellowDog.Config.get_dns_zone("example.com")
      {:ok, %{type: "authoritative", file: "zones/example.com.zone"}}

      iex> YellowDog.Config.get_dns_zone("nonexistent.com")
      {:error, :not_found}
  """
  @spec get_dns_zone(zone_name()) :: {:ok, map()} | {:error, :not_found}
  def get_dns_zone(zone_name) do
    zones = get_dns_zones()

    case Map.get(zones, zone_name) do
      nil -> {:error, :not_found}
      zone_config -> {:ok, zone_config}
    end
  end

  @doc """
  Lists all configured DNS zone names.

  ## Examples

      iex> YellowDog.Config.list_dns_zones()
      ["example.com", "test.local"]
  """
  @spec list_dns_zones() :: [zone_name()]
  def list_dns_zones do
    zones = get_dns_zones()
    Map.keys(zones)
  end

  @doc """
  Checks if a zone is configured and enabled.

  ## Examples

      iex> YellowDog.Config.dns_zone_enabled?("example.com")
      true

      iex> YellowDog.Config.dns_zone_enabled?("nonexistent.com")
      false
  """
  @spec dns_zone_enabled?(zone_name()) :: boolean()
  def dns_zone_enabled?(zone_name) do
    case get_dns_zone(zone_name) do
      {:ok, _zone_config} -> true
      {:error, :not_found} -> false
    end
  end

  @doc """
  Gets the type of a DNS zone.

  ## Examples

      iex> YellowDog.Config.get_dns_zone_type("example.com")
      {:ok, :authoritative}

      iex> YellowDog.Config.get_dns_zone_type("nonexistent.com")
      {:error, :not_found}
  """
  @spec get_dns_zone_type(zone_name()) :: {:ok, zone_type()} | {:error, :not_found}
  def get_dns_zone_type(zone_name) do
    case get_dns_zone(zone_name) do
      {:ok, zone_config} ->
        type_str = Map.get(zone_config, "type", "authoritative")

        type =
          case type_str do
            "authoritative" -> :authoritative
            "stub" -> :stub
            "forward" -> :forward
            "cache" -> :cache
            _ -> :authoritative
          end

        {:ok, type}

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Gets the zone file path for a DNS zone.

  ## Examples

      iex> YellowDog.Config.get_dns_zone_file("example.com")
      {:ok, "zones/example.com.zone"}

      iex> YellowDog.Config.get_dns_zone_file("nonexistent.com")
      {:error, :not_found}
  """
  @spec get_dns_zone_file(zone_name()) :: {:ok, String.t()} | {:error, :not_found}
  def get_dns_zone_file(zone_name) do
    with {:ok, zone_config} <- get_dns_zone(zone_name),
         file_path when is_binary(file_path) <- Map.get(zone_config, "file") do
      {:ok, file_path}
    else
      {:error, :not_found} -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Updates configuration for a specific service.

  New config will be loaded on next service restart.

  ## Examples

      iex> new_config = %{port: 5353, listen: "127.0.0.1"}
      iex> YellowDog.Config.update(:dns, new_config)
      :ok
  """
  @spec update(service_name(), map()) :: :ok
  def update(service, new_config) do
    Agent.update(__MODULE__, fn state ->
      config = effective_config(state)
      key = if Map.has_key?(config, service), do: service, else: to_string(service)
      put_effective_config(state, Map.put(config, key, new_config))
    end)
  end

  @doc """
  Compare-and-swap update with version checking.

  Atomically updates configuration only if the version matches expected.
  Used for optimistic locking in web console.

  ## Parameters
    - service: Service atom (:dns, :mdns, :dhcpv4, :dhcpv6)
    - new_config: New configuration map
    - expected_version: Expected current version number

  ## Returns
    - `:ok` if version matches and update successful
    - `{:error, :version_mismatch}` if version doesn't match

  ## Examples

      iex> YellowDog.Config.compare_and_swap(:dns, %{port: 5353}, 1)
      :ok

      iex> YellowDog.Config.compare_and_swap(:dns, %{port: 5353}, 99)
      {:error, :version_mismatch}
  """
  @spec compare_and_swap(service_name(), map(), non_neg_integer()) ::
          :ok | {:error, :version_mismatch}
  def compare_and_swap(service, new_config, expected_version) do
    Agent.get_and_update(__MODULE__, fn state ->
      config = effective_config(state)
      current_version = Map.get(config, :_version, 0)

      if current_version == expected_version do
        new_state =
          config
          |> put_in([to_string(service)], new_config)
          |> Map.put(:_version, current_version + 1)

        {:ok, put_effective_config(state, new_state)}
      else
        {{:error, :version_mismatch}, state}
      end
    end)
  end

  @doc """
  Gets the current configuration version.

  Used for optimistic locking to track configuration changes.

  ## Examples

      iex> YellowDog.Config.get_version()
      0
  """
  @spec get_version() :: non_neg_integer()
  def get_version do
    Agent.get(__MODULE__, fn state -> state |> effective_config() |> Map.get(:_version, 0) end)
  end

  @doc """
  Gets the base data directory for all services.

  Priority order:
  1. CLI argument `--data-dir` (via Application.get_env)
  2. Environment variable `YELLOW_DOG_DATA_DIR`
  3. Config file `data_dir` setting
  4. Default: "data"

  ## Examples

      iex> YellowDog.Config.get_data_dir()
      "/data/yellowdog"
  """
  @spec get_data_dir() :: String.t()
  def get_data_dir do
    dir =
      case Application.get_env(:yellow_dog, :data_dir) do
        dir when is_binary(dir) and dir != "" -> dir
        _other -> configured_data_dir() || "data"
      end

    resolve_data_dir(dir)
  end

  defp configured_data_dir do
    agent_data_dir() || config_file_data_dir()
  end

  defp agent_data_dir do
    if Process.whereis(__MODULE__) do
      try do
        case get("data_dir") do
          dir when is_binary(dir) and dir != "" -> dir
          _other -> nil
        end
      catch
        :exit, _reason -> nil
      end
    end
  end

  defp config_file_data_dir do
    with path when is_binary(path) <- Application.get_env(:yellow_dog, :config_file_path),
         {:ok, config} <- load(path),
         dir when is_binary(dir) and dir != "" <- Map.get(config, "data_dir") do
      dir
    else
      _other -> nil
    end
  rescue
    _exception -> nil
  end

  @doc """
  Gets the data directory for a specific service.

  Returns the path: `<data_dir>/<service_name>/`

  ## Examples

      iex> YellowDog.Config.get_service_data_dir(:dns)
      "data/dns"

      iex> YellowDog.Config.get_service_data_dir(:dhcpv4)
      "/data/yellowdog/dhcpv4"
  """
  @spec get_service_data_dir(service_name()) :: String.t()
  def get_service_data_dir(service) do
    base_dir = get_data_dir()
    Path.join(base_dir, to_string(service))
  end

  @doc """
  Ensures the data directory for a service exists.

  Creates the directory if it doesn't exist.

  ## Examples

      iex> YellowDog.Config.ensure_service_data_dir(:dns)
      :ok
  """
  @spec ensure_service_data_dir(service_name()) :: :ok | {:error, term()}
  def ensure_service_data_dir(service) do
    service |> get_service_data_dir() |> File.mkdir_p()
  end

  @doc """
  Gets the Mnesia directory for persistent storage.

  Used by DHCPv4 and DHCPv6 for lease persistence.

  ## Examples

      iex> YellowDog.Config.get_mnesia_dir()
      "data/mnesia"
  """
  @spec get_mnesia_dir() :: String.t()
  def get_mnesia_dir do
    base_dir = get_data_dir()
    Path.join(base_dir, "mnesia")
  end

  @doc """
  Ensures the Mnesia directory exists.

  ## Examples

      iex> YellowDog.Config.ensure_mnesia_dir()
      :ok
  """
  @spec ensure_mnesia_dir() :: :ok | {:error, term()}
  def ensure_mnesia_dir do
    get_mnesia_dir() |> File.mkdir_p()
  end

  # Resolves a relative data_dir to the umbrella root so that all apps
  # share a single data directory instead of each creating their own
  # under apps/<app_name>/data/.
  @fallback_data_root "/var/lib/yellow-dog"

  defp resolve_data_dir("/" <> _ = absolute), do: absolute

  defp resolve_data_dir(relative) when is_binary(relative) do
    Path.join(umbrella_root(), relative)
  end

  defp resolve_data_dir(_relative), do: resolve_data_dir("data")

  defp umbrella_root do
    case application_dir(:yellow_dog) || application_dir(:yellow_dog_config) do
      app_dir when is_binary(app_dir) -> app_dir |> Path.join("../..") |> Path.expand()
      nil -> @fallback_data_root
    end
  end

  defp application_dir(application) do
    Application.app_dir(application)
  rescue
    ArgumentError -> nil
  end
end
