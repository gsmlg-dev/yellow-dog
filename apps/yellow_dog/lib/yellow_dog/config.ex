defmodule YellowDog.Config do
  @moduledoc """
  Configuration management for YellowDog with TOML file support.

  Provides API for service applications to query their configuration
  and check if they are enabled.
  """

  use Agent
  require Logger

  @type config_map :: map()
  @type service_name :: :dns | :mdns | :dhcpv4 | :dhcpv6
  @type config_key :: atom()
  @type config_value :: term()

  # Default configuration fallback (now defined in application)
  @default_config %{}

  @doc """
  Starts the configuration agent with the given config.
  """
  def start_link(config) do
    Agent.start_link(fn -> config end, name: __MODULE__)
  end

  @doc """
  Gets all configuration as a map.
  """
  @spec get_all() :: config_map()
  def get_all do
    Agent.get(__MODULE__, fn state -> state end)
  end

  @doc """
  Gets a configuration value by name.
  """
  @spec get(config_key()) :: config_value()
  def get(name) do
    Agent.get(__MODULE__, fn state -> Map.get(state, name) end)
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
      %{"core" => core_config} ->
        Map.get(core_config, to_string(service), true)

      core_config when is_map(core_config) ->
        Map.get(core_config, to_string(service), true)

      _ ->
        true
    end
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
        for {key, val} <- service_config, into: %{}, do: {String.to_atom(key), val}

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
            Logger.info("Loaded configuration from #{path}")
            {:ok, config}

          {:error, reason} ->
            Logger.error("Failed to parse TOML from #{path}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to read config file #{path}: #{inspect(reason)}")
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
        Logger.warning("Using default configuration due to load failure")
        @default_config
    end
  end

  # Private helper functions

  defp get_default_service_config(service) do
    case Map.get(@default_config, to_string(service)) do
      nil ->
        %{}

      config ->
        for {key, val} <- config, into: %{}, do: {String.to_atom(key), val}
    end
  end

  defp get_default_value(service, key) do
    service_config = get_default_service_config(service)
    Map.get(service_config, key)
  end
end
