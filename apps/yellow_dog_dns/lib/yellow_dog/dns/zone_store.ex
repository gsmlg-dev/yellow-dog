defmodule YellowDog.Dns.ZoneStore do
  @moduledoc """
  Persistence layer for DNS zone metadata configurations.

  **Deprecated**: Zone configuration is now managed via `YellowDog.Store.Zone`.
  Use `migrate_to_store/0` to migrate existing TOML zones to Store.

  Handles loading and saving zone metadata from/to TOML files.
  Note: Resource records are stored in standard BIND zone files via Zone.Auth.

  ## File Format

  Zone metadata is stored in TOML format:

      [zones."example.com"]
      type = "auth"
      file = "zones/example.com.zone"

      [zones."internal.example.com"]
      type = "auth"
      file = "zones/internal.example.com.zone"

      [zones."."]
      type = "forward"
      upstreams = ["8.8.8.8:53", "8.8.4.4:53"]
  """

  use YellowDog.Data.Collection

  defcollection(:dns_zones,
    key_field: :name,
    adapter: YellowDog.Data.Store.Ets,
    persistence: [strategy: :toml, path: "data/dns/zones.toml"]
  )

  import YellowDog.Config.TomlHelpers,
    only: [
      parse_toml: 1,
      get_value: 2,
      get_value: 3,
      get_integer: 3,
      get_list: 2,
      encode_toml_string: 1,
      ensure_directory: 1,
      maybe_create_backup: 2,
      atomic_write: 2
    ]

  @type zone_type :: :auth | :forward | :stub | :cache | :root | :rpz
  @type zone_config :: %{
          name: String.t(),
          type: zone_type(),
          view_name: String.t() | nil,
          file: String.t() | nil,
          upstreams: [String.t()] | nil,
          ns_records: [String.t()] | nil,
          ttl: pos_integer() | nil
        }

  @doc """
  Loads zone metadata from a TOML file.

  ## Parameters
  - `file_path` - Path to the zones TOML file

  ## Returns
  - `{:ok, [zone_config]}` on success
  - `{:error, reason}` on failure (returns empty list for missing file)
  """
  @spec load_zones(String.t()) :: {:ok, [zone_config()]} | {:error, term()}
  def load_zones(file_path) do
    with {:ok, content} <- File.read(file_path),
         {:ok, raw_data} <- parse_toml(content),
         {:ok, zones} <- extract_zones(raw_data) do
      validated_zones =
        for zone <- zones,
            {:ok, validated} <- [validate_and_normalize_zone(zone)],
            do: validated

      :telemetry.execute(
        [:yellow_dog, :dns, :zone_store, :loaded],
        %{zone_count: length(validated_zones)},
        %{file_path: file_path}
      )

      {:ok, validated_zones}
    else
      {:error, :enoent} ->
        :telemetry.execute(
          [:yellow_dog, :dns, :zone_store, :file_not_found],
          %{count: 1},
          %{file_path: file_path}
        )

        {:ok, []}

      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :dns, :zone_store, :load_failed],
          %{count: 1},
          %{file_path: file_path, reason: inspect(reason)}
        )

        error
    end
  end

  @doc """
  Saves zone metadata to a TOML file.

  Performs atomic write by writing to a temporary file first, then renaming.
  Creates a backup of the existing file if it exists.

  ## Parameters
  - `file_path` - Path to save the zones file
  - `zones` - List of zone configurations
  - `opts` - Options
    - `:backup` - Create backup before overwriting (default: true)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec save_zones(String.t(), [zone_config()], keyword()) :: :ok | {:error, term()}
  def save_zones(file_path, zones, opts \\ []) do
    create_backup? = Keyword.get(opts, :backup, true)

    with {:ok, content} <- format_zones(zones),
         :ok <- ensure_directory(file_path),
         :ok <- maybe_create_backup(file_path, create_backup?),
         :ok <- atomic_write(file_path, content) do
      :telemetry.execute(
        [:yellow_dog, :dns, :zone_store, :saved],
        %{zone_count: length(zones)},
        %{file_path: file_path}
      )

      :ok
    else
      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :dns, :zone_store, :save_failed],
          %{count: 1},
          %{file_path: file_path, reason: inspect(reason)}
        )

        error
    end
  end

  @doc """
  Migrates zone configurations from TOML to YellowDog.Store.

  Reads zones from the default TOML file and creates them in Store.
  Skips zones that already exist in Store (CAS prevents duplicates).

  Returns `{:ok, %{migrated: n, skipped: n, errors: n}}`.
  """
  @deprecated "Zone data should be managed via YellowDog.Store.Zone"
  @spec migrate_to_store() :: {:ok, map()}
  def migrate_to_store do
    migrate_to_store("data/dns/zones.toml")
  end

  @spec migrate_to_store(String.t()) :: {:ok, map()}
  def migrate_to_store(file_path) do
    case load_zones(file_path) do
      {:ok, zones} ->
        results =
          Enum.reduce(zones, %{migrated: 0, skipped: 0, errors: 0}, fn zone, acc ->
            case migrate_zone_to_store(zone) do
              :ok -> %{acc | migrated: acc.migrated + 1}
              :skipped -> %{acc | skipped: acc.skipped + 1}
              :error -> %{acc | errors: acc.errors + 1}
            end
          end)

        {:ok, results}

      {:error, _} ->
        {:ok, %{migrated: 0, skipped: 0, errors: 0}}
    end
  end

  defp migrate_zone_to_store(%{type: :auth} = zone) do
    view = zone[:view_name] || "default"

    soa = %{
      mname: "ns1.#{zone.name}",
      rname: "hostmaster.#{zone.name}",
      serial: 1,
      refresh: 3600,
      retry: 1800,
      expire: 604_800,
      minimum: 86_400
    }

    opts = if zone[:ttl], do: [default_ttl: zone.ttl], else: []

    case YellowDog.Store.Zone.create_zone(view, zone.name, soa, opts) do
      :ok -> :ok
      {:error, :already_exists} -> :skipped
      {:error, _} -> :error
    end
  end

  defp migrate_zone_to_store(%{type: :forward} = zone) do
    view = zone[:view_name] || "default"

    forwarders =
      (zone[:upstreams] || [])
      |> Enum.flat_map(fn upstream ->
        case String.split(upstream, ":") do
          [ip, port_str] ->
            case Integer.parse(port_str) do
              {port, ""} -> [%{ip: ip, port: port}]
              _ -> [%{ip: ip, port: 53}]
            end

          [ip] ->
            [%{ip: ip, port: 53}]

          _ ->
            []
        end
      end)

    case YellowDog.Store.Zone.create_forward_zone(view, zone.name, forwarders) do
      :ok -> :ok
      {:error, :already_exists} -> :skipped
      {:error, _} -> :error
    end
  end

  defp migrate_zone_to_store(%{type: :stub} = zone) do
    view = zone[:view_name] || "default"

    primaries =
      (zone[:ns_records] || [])
      |> Enum.map(fn ns -> %{ip: ns, port: 53} end)

    case YellowDog.Store.Zone.create_stub_zone(view, zone.name, primaries) do
      :ok -> :ok
      {:error, :already_exists} -> :skipped
      {:error, _} -> :error
    end
  end

  defp migrate_zone_to_store(_zone), do: :skipped

  @doc """
  Validates a zone configuration.

  ## Parameters
  - `zone` - Zone configuration map

  ## Returns
  - `:ok` if valid
  - `{:error, reason}` if invalid
  """
  @spec validate_zone(map()) :: :ok | {:error, String.t()}
  def validate_zone(zone) do
    with :ok <- validate_required_fields(zone),
         :ok <- validate_name(zone.name),
         :ok <- validate_type(zone.type),
         :ok <- validate_type_specific(zone) do
      :ok
    end
  end

  # Private functions

  defp extract_zones(data) do
    case Map.get(data, "zones") do
      nil ->
        {:ok, []}

      zones when is_map(zones) ->
        zone_list =
          Enum.map(zones, fn {key, config} ->
            # Key format is either "zone_name" or "view_name:zone_name"
            # If view_name is in config, use that; otherwise parse from key
            {zone_name, view_name} = parse_zone_key(key, config)

            config
            |> Map.put("name", zone_name)
            |> Map.put_new("view_name", view_name)
          end)

        {:ok, zone_list}
    end
  end

  # Parse zone key to extract zone name and view name
  # Key format: "zone_name" (default view) or "view_name:zone_name"
  defp parse_zone_key(key, config) do
    # If view_name is already in config, use the key as zone name
    if Map.has_key?(config, "view_name") do
      # Parse the zone name from the key (strip view prefix if present)
      zone_name =
        case String.split(key, ":", parts: 2) do
          [_view, name] -> name
          [name] -> name
        end

      {zone_name, config["view_name"]}
    else
      # Legacy format: key is just zone name, belongs to default view
      case String.split(key, ":", parts: 2) do
        [view_name, zone_name] -> {zone_name, view_name}
        [zone_name] -> {zone_name, "default"}
      end
    end
  end

  defp validate_and_normalize_zone(zone) do
    normalized = normalize_zone_keys(zone)

    with :ok <- validate_zone(normalized), do: {:ok, normalized}
  end

  defp normalize_zone_keys(zone) when is_map(zone) do
    %{
      name: get_value(zone, [:name, "name"]),
      type: normalize_type(get_value(zone, [:type, "type"], "auth")),
      view_name: get_value(zone, [:view_name, "view_name"], "default"),
      file: get_value(zone, [:file, "file"]),
      upstreams: get_list(zone, [:upstreams, "upstreams"]),
      ns_records: get_list(zone, [:ns_records, "ns_records"]),
      ttl: get_integer(zone, [:ttl, "ttl"], nil)
    }
  end

  @zone_types %{
    "auth" => :auth,
    "forward" => :forward,
    "stub" => :stub,
    "cache" => :cache,
    "root" => :root,
    "rpz" => :rpz
  }

  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type(type), do: Map.get(@zone_types, type, :auth)

  defp validate_required_fields(zone) do
    cond do
      is_nil(Map.get(zone, :name)) ->
        {:error, "Missing required field: name"}

      is_nil(Map.get(zone, :type)) ->
        {:error, "Missing required field: type"}

      true ->
        :ok
    end
  end

  defp validate_name(name) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp validate_name(_), do: {:error, "Invalid zone name"}

  defp validate_type(type) when type in [:auth, :forward, :stub, :cache, :root, :rpz], do: :ok
  defp validate_type(_), do: {:error, "Invalid zone type"}

  defp validate_type_specific(%{type: :forward, upstreams: upstreams})
       when is_nil(upstreams) or upstreams == [] do
    {:error, "Forward zones require upstreams"}
  end

  defp validate_type_specific(%{type: :stub, ns_records: ns_records})
       when is_nil(ns_records) or ns_records == [] do
    {:error, "Stub zones require ns_records"}
  end

  defp validate_type_specific(_), do: :ok

  defp format_zones(zones) do
    header = """
    # DNS Zone Metadata Configuration
    # Generated by YellowDog DNS
    #
    # This file contains zone metadata. Resource records are stored
    # in standard BIND zone files referenced by the 'file' field.
    """

    zones_content = Enum.map_join(zones, "\n", &zone_to_toml/1)

    {:ok, header <> "\n" <> zones_content}
  end

  defp zone_to_toml(zone) do
    name = zone.name
    type = Atom.to_string(zone.type)
    view_name = zone[:view_name] || "default"

    # Use view_name:zone_name as key to ensure uniqueness across views
    zone_key =
      if view_name == "default" do
        name
      else
        "#{view_name}:#{name}"
      end

    base = [
      "",
      "[zones.#{encode_toml_key(zone_key)}]",
      "type = #{encode_toml_string(type)}",
      "view_name = #{encode_toml_string(view_name)}"
    ]

    optional =
      [
        zone[:file] && "file = #{encode_toml_string(zone.file)}",
        zone[:upstreams] && zone.upstreams != [] &&
          "upstreams = [#{Enum.map_join(zone.upstreams, ", ", &encode_toml_string/1)}]",
        zone[:ns_records] && zone.ns_records != [] &&
          "ns_records = [#{Enum.map_join(zone.ns_records, ", ", &encode_toml_string/1)}]",
        zone[:ttl] && "ttl = #{zone.ttl}"
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(base ++ optional, "\n")
  end

  defp encode_toml_key(key) when is_binary(key) do
    # Zone names may contain dots, so we need to quote them
    "\"#{String.replace(key, "\"", "\\\"")}\""
  end
end
