defmodule YellowDog.Mdns.ServiceStore do
  @moduledoc """
  Persistence layer for mDNS service definitions.

  Handles loading and saving service configurations from/to TOML or JSON files.
  Supports file watching for hot-reload and atomic writes with backup.
  """

  import YellowDog.Config.TomlHelpers,
    only: [
      parse_toml: 1,
      get_value: 2,
      get_integer: 3,
      get_boolean: 3,
      get_map: 3,
      encode_toml_string: 1,
      ensure_directory: 1,
      maybe_create_backup: 2,
      atomic_write: 2
    ]

  @type service_def :: %{
          name: String.t(),
          type: String.t(),
          port: pos_integer(),
          host: String.t() | nil,
          txt: map() | nil,
          addresses: [String.t()] | nil,
          enabled: boolean()
        }

  @type format :: :toml | :json

  @doc """
  Loads services from a file.

  Supports both TOML and JSON formats, auto-detecting based on file extension
  or using the provided format parameter.

  ## Parameters
  - `file_path` - Path to the services file
  - `opts` - Options
    - `:format` - Force format (:toml or :json), defaults to auto-detect

  ## Returns
  - `{:ok, [service_def]}` on success
  - `{:error, reason}` on failure

  ## Examples
      iex> YellowDog.Mdns.ServiceStore.load_services("/path/to/services.toml")
      {:ok, [%{name: "Web Server", type: "_http._tcp", port: 8080, ...}]}
  """
  @spec load_services(String.t(), keyword()) :: {:ok, [service_def()]} | {:error, term()}
  def load_services(file_path, opts \\ []) do
    with {:ok, content} <- File.read(file_path),
         format <- determine_format(file_path, opts),
         {:ok, raw_data} <- parse_content(content, format),
         {:ok, services} <- extract_services(raw_data, format) do
      validated_services =
        services
        |> Enum.map(&validate_and_normalize_service/1)
        |> Enum.reject(&match?({:error, _}, &1))
        |> Enum.map(fn {:ok, service} -> service end)

      :telemetry.execute(
        [:yellow_dog, :mdns, :service_store, :loaded],
        %{service_count: length(validated_services)},
        %{file_path: file_path}
      )

      {:ok, validated_services}
    else
      {:error, :enoent} ->
        :telemetry.execute(
          [:yellow_dog, :mdns, :service_store, :file_not_found],
          %{count: 1},
          %{file_path: file_path}
        )

        {:ok, []}

      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :mdns, :service_store, :load_failed],
          %{count: 1},
          %{file_path: file_path, reason: inspect(reason)}
        )

        error
    end
  end

  @doc """
  Saves services to a file.

  Performs atomic write by writing to a temporary file first, then renaming.
  Creates a backup of the existing file if it exists.

  ## Parameters
  - `file_path` - Path to save the services file
  - `services` - List of service definitions
  - `opts` - Options
    - `:format` - Format to use (:toml or :json), defaults to auto-detect
    - `:backup` - Create backup before overwriting (default: true)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec save_services(String.t(), [service_def()], keyword()) :: :ok | {:error, term()}
  def save_services(file_path, services, opts \\ []) do
    format = determine_format(file_path, opts)
    create_backup? = Keyword.get(opts, :backup, true)

    with {:ok, content} <- format_services(services, format),
         :ok <- ensure_directory(file_path),
         :ok <- maybe_create_backup(file_path, create_backup?),
         :ok <- atomic_write(file_path, content) do
      :telemetry.execute(
        [:yellow_dog, :mdns, :service_store, :saved],
        %{service_count: length(services)},
        %{file_path: file_path}
      )

      :ok
    else
      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :mdns, :service_store, :save_failed],
          %{count: 1},
          %{file_path: file_path, reason: inspect(reason)}
        )

        error
    end
  end

  @doc """
  Validates a service definition.

  ## Parameters
  - `service` - Service definition map

  ## Returns
  - `:ok` if valid
  - `{:error, reason}` if invalid
  """
  @spec validate_service(map()) :: :ok | {:error, String.t()}
  def validate_service(service) do
    with :ok <- validate_required_fields(service),
         :ok <- validate_name(service.name),
         :ok <- validate_type(service.type),
         :ok <- validate_port(service.port),
         :ok <- validate_addresses(Map.get(service, :addresses)),
         :ok <- validate_txt_records(Map.get(service, :txt)) do
      :ok
    end
  end

  # Private functions

  defp determine_format(file_path, opts) do
    case Keyword.get(opts, :format) do
      format when format in [:toml, :json] ->
        format

      nil ->
        case Path.extname(file_path) do
          ".toml" -> :toml
          ".json" -> :json
          _ -> :toml
        end
    end
  end

  defp parse_content(content, :toml), do: parse_toml(content)

  defp parse_content(content, :json) do
    case Jason.decode(content, keys: :atoms) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  defp extract_services(data, :toml) do
    case Map.get(data, "service") do
      nil -> {:ok, []}
      services when is_list(services) -> {:ok, services}
      service when is_map(service) -> {:ok, [service]}
    end
  end

  defp extract_services(data, :json) do
    case Map.get(data, :services) do
      nil -> {:ok, []}
      services when is_list(services) -> {:ok, services}
      _ -> {:error, :invalid_json_structure}
    end
  end

  defp validate_and_normalize_service(service) do
    normalized = normalize_service_keys(service)

    case validate_service(normalized) do
      :ok -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_service_keys(service) when is_map(service) do
    %{
      name: get_value(service, [:name, "name"]),
      type: get_value(service, [:type, "type"]),
      port: get_integer(service, [:port, "port"], nil),
      host: get_value(service, [:host, "host"]),
      txt: get_map(service, [:txt, "txt"], %{}),
      addresses: get_addresses(service),
      enabled: get_boolean(service, [:enabled, "enabled"], true)
    }
  end

  defp get_addresses(service) do
    # Try different key formats
    case Map.get(service, :addresses) || Map.get(service, "addresses") do
      nil -> []
      addresses when is_list(addresses) -> addresses
      addresses when is_map(addresses) -> flatten_addresses(addresses)
      _ -> []
    end
  end

  defp flatten_addresses(addresses_map) when is_map(addresses_map) do
    # Handle nested structure like %{ipv4: [...], ipv6: [...]}
    ipv4 = Map.get(addresses_map, :ipv4) || Map.get(addresses_map, "ipv4") || []
    ipv6 = Map.get(addresses_map, :ipv6) || Map.get(addresses_map, "ipv6") || []

    ipv4 ++ ipv6
  end

  defp validate_required_fields(service) do
    required = [:name, :type, :port]

    missing =
      Enum.filter(required, fn field ->
        is_nil(Map.get(service, field))
      end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_name(name) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp validate_name(_), do: {:error, "Invalid name"}

  defp validate_type(type) when is_binary(type) do
    if String.starts_with?(type, "_") or String.contains?(type, "._") do
      :ok
    else
      {:error, "Service type must start with _ or contain ._ (e.g., _http._tcp)"}
    end
  end

  defp validate_type(_), do: {:error, "Invalid type"}

  defp validate_port(port) when is_integer(port) and port > 0 and port < 65536, do: :ok
  defp validate_port(_), do: {:error, "Port must be between 1 and 65535"}

  defp validate_addresses(nil), do: :ok
  defp validate_addresses([]), do: :ok

  defp validate_addresses(addresses) when is_list(addresses) do
    invalid =
      Enum.reject(addresses, fn addr ->
        is_binary(addr) and (valid_ipv4?(addr) or valid_ipv6?(addr))
      end)

    if Enum.empty?(invalid) do
      :ok
    else
      {:error, "Invalid IP addresses: #{inspect(invalid)}"}
    end
  end

  defp validate_addresses(_), do: {:error, "Addresses must be a list"}

  defp validate_txt_records(nil), do: :ok
  defp validate_txt_records(txt) when is_map(txt), do: :ok
  defp validate_txt_records(_), do: {:error, "TXT records must be a map"}

  defp valid_ipv4?(addr) do
    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, {_, _, _, _}} -> true
      _ -> false
    end
  end

  defp valid_ipv6?(addr) do
    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, {_, _, _, _, _, _, _, _}} -> true
      _ -> false
    end
  end

  defp format_services(services, :toml) do
    # The toml library (v0.7) is decode-only, so we implement basic TOML encoding
    # for the limited structure we need (array of tables)
    toml_content = Enum.map_join(services, "\n", &service_to_toml/1)

    {:ok, toml_content}
  end

  defp format_services(services, :json) do
    json_data = %{services: services}

    case Jason.encode(json_data, pretty: true) do
      {:ok, content} -> {:ok, content}
      error -> error
    end
  end

  defp service_to_toml(service) do
    lines = [
      "[[service]]",
      "name = #{encode_toml_string(service.name)}",
      "type = #{encode_toml_string(service.type)}",
      "port = #{service.port}",
      "enabled = #{service[:enabled] || true}"
    ]

    lines =
      if service[:host] do
        lines ++ ["host = #{encode_toml_string(service.host)}"]
      else
        lines
      end

    lines =
      if service[:txt] && map_size(service.txt) > 0 do
        txt_lines =
          ["", "  [service.txt]"] ++
            Enum.map(service.txt, fn {k, v} ->
              "  #{k} = #{encode_toml_string(v)}"
            end)

        lines ++ txt_lines
      else
        lines
      end

    lines =
      if service[:addresses] && service.addresses != [] do
        ipv4 = Enum.filter(service.addresses, &valid_ipv4?/1)
        ipv6 = Enum.filter(service.addresses, &valid_ipv6?/1)

        addr_lines = []

        addr_lines =
          if Enum.any?(ipv4) || Enum.any?(ipv6),
            do: addr_lines ++ ["", "  [service.addresses]"],
            else: addr_lines

        addr_lines =
          if Enum.any?(ipv4),
            do: addr_lines ++ ["  ipv4 = [#{Enum.map_join(ipv4, ", ", &encode_toml_string/1)}]"],
            else: addr_lines

        addr_lines =
          if Enum.any?(ipv6),
            do: addr_lines ++ ["  ipv6 = [#{Enum.map_join(ipv6, ", ", &encode_toml_string/1)}]"],
            else: addr_lines

        lines ++ addr_lines
      else
        lines
      end

    Enum.join(lines, "\n")
  end

end
