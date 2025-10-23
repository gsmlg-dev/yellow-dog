defmodule DNS.Zone.Manager do
  @moduledoc """
  Zone management system for DNS zones.

  Provides CRUD operations for zone management, zone lifecycle operations,
  and zone coordination across the DNS system.
  """

  alias DNS.Zone
  alias DNS.Zone.Store
  alias DNS.Zone.Loader

  @type zone_name :: String.t()
  @type zone_type :: :authoritative | :stub | :forward | :cache
  @type zone_data :: map()

  @doc """
  Load a zone from a file.
  """
  @spec load_zone_from_file(zone_name, String.t()) :: {:ok, Zone.t()} | {:error, String.t()}
  def load_zone_from_file(_name, file_path) do
    case Zone.parse_zone_file(file_path) do
      {:ok, zone} ->
        {:ok, zone}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Load a zone from string content.
  """
  @spec load_zone_from_string(zone_name, String.t()) :: {:ok, Zone.t()} | {:error, String.t()}
  def load_zone_from_string(_name, content) do
    case Zone.parse_zone_string(content) do
      {:ok, zone} ->
        {:ok, zone}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Create a new zone with basic configuration.
  """
  @spec create_zone(zone_name, zone_type, keyword()) :: {:ok, Zone.t()} | {:error, String.t()}
  def create_zone(name, type \\ :authoritative, options \\ []) do
    Store.ensure_initialized()
    zone = Zone.new(name, type, options)
    Store.put_zone(zone)
  end

  @doc """
  Get a zone by name.
  """
  @spec get_zone(zone_name) :: {:ok, Zone.t()} | {:error, :not_found}
  def get_zone(name) do
    Store.ensure_initialized()
    Store.get_zone(name)
  end

  @doc """
  List all zones.
  """
  @spec list_zones() :: list(Zone.t())
  def list_zones() do
    Store.ensure_initialized()
    Store.list_zones()
  end

  @doc """
  Update zone configuration.
  """
  @spec update_zone(zone_name, keyword()) :: {:ok, Zone.t()} | {:error, String.t()}
  def update_zone(name, options) do
    Store.ensure_initialized()

    case Store.get_zone(name) do
      {:ok, zone} ->
        updated_zone = %{zone | options: Keyword.merge(zone.options || [], options)}
        Store.put_zone(updated_zone)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Delete a zone.
  """
  @spec delete_zone(zone_name) :: :ok | {:error, String.t()}
  def delete_zone(name) do
    Store.ensure_initialized()
    Store.delete_zone(name)
  end

  @doc """
  Reload a zone from its source file.
  """
  @spec reload_zone(zone_name) :: {:ok, Zone.t()} | {:error, String.t()}
  def reload_zone(name) do
    case Store.get_zone(name) do
      {:ok, zone} ->
        Loader.reload_zone(zone)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Initialize the zone management system.

  This function initializes the zone store and clears any existing zones.
  It is primarily used for testing to ensure a clean state.
  """
  @spec init() :: :ok
  def init() do
    Store.init()
    Store.clear()
  end

  @doc """
  Validate zone configuration.
  """
  @spec validate_zone(Zone.t()) :: {:ok, Zone.t()} | {:error, list(String.t())}
  def validate_zone(zone) do
    errors = []

    # Validate zone name
    errors = validate_zone_name(zone.name, errors)

    # Validate zone type
    errors = validate_zone_type(zone.type, errors)

    # Validate zone options
    errors = validate_zone_options(zone.options, errors)

    if Enum.empty?(errors) do
      {:ok, zone}
    else
      {:error, errors}
    end
  end

  ## Private functions

  defp validate_zone_name(name, errors) do
    name_str = if is_struct(name, DNS.Zone.Name), do: name.value, else: to_string(name)

    if is_binary(name_str) and String.trim(name_str) != "" do
      errors
    else
      ["Zone name must be a non-empty string" | errors]
    end
  end

  defp validate_zone_type(type, errors) do
    if type in [:authoritative, :stub, :forward, :cache] do
      errors
    else
      ["Invalid zone type: #{type}" | errors]
    end
  end

  defp validate_zone_options(options, errors) do
    # Basic option validation
    Enum.reduce(options, errors, fn
      {:ttl, ttl}, acc when is_integer(ttl) and ttl > 0 -> acc
      {:ttl, ttl}, acc -> ["TTL must be a positive integer: #{ttl}" | acc]
      {:origin, origin}, acc when is_binary(origin) -> acc
      {:origin, origin}, acc -> ["Origin must be a string: #{inspect(origin)}" | acc]
      _, acc -> acc
    end)
  end
end
