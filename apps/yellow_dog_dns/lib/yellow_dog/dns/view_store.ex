defmodule YellowDog.Dns.ViewStore do
  @moduledoc """
  Persistence layer for DNS view configurations.

  Handles loading and saving view configurations from/to TOML files.
  Supports atomic writes with backup to prevent data corruption.

  ## File Format

  Views are stored in TOML format:

      [[view]]
      name = "internal"
      priority = 10
      match_clients = "localnets"
      recursion = true
      ecs_enabled = false
      zones = ["example.com", "internal.example.com"]

      [[view.acl]]
      action = "allow"
      network = "10.0.0.0/8"
  """

  @type view_config :: %{
          name: String.t(),
          priority: integer(),
          match_clients: String.t() | nil,
          recursion: boolean(),
          ecs_enabled: boolean(),
          zones: [String.t()],
          acl: [%{action: String.t(), network: String.t()}] | nil
        }

  @doc """
  Loads views from a TOML file.

  ## Parameters
  - `file_path` - Path to the views TOML file

  ## Returns
  - `{:ok, [view_config]}` on success
  - `{:error, reason}` on failure (returns empty list for missing file)

  ## Examples

      iex> YellowDog.Dns.ViewStore.load_views("data/dns/views.toml")
      {:ok, [%{name: "internal", priority: 10, ...}]}
  """
  @spec load_views(String.t()) :: {:ok, [view_config()]} | {:error, term()}
  def load_views(file_path) do
    with {:ok, content} <- File.read(file_path),
         {:ok, raw_data} <- parse_toml(content),
         {:ok, views} <- extract_views(raw_data) do
      validated_views =
        views
        |> Enum.map(&validate_and_normalize_view/1)
        |> Enum.reject(&match?({:error, _}, &1))
        |> Enum.map(fn {:ok, view} -> view end)

      :telemetry.execute(
        [:yellow_dog, :dns, :view_store, :loaded],
        %{view_count: length(validated_views)},
        %{file_path: file_path}
      )

      {:ok, validated_views}
    else
      {:error, :enoent} ->
        :telemetry.execute(
          [:yellow_dog, :dns, :view_store, :file_not_found],
          %{count: 1},
          %{file_path: file_path}
        )

        {:ok, []}

      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :dns, :view_store, :load_failed],
          %{count: 1},
          %{file_path: file_path, reason: inspect(reason)}
        )

        error
    end
  end

  @doc """
  Saves views to a TOML file.

  Performs atomic write by writing to a temporary file first, then renaming.
  Creates a backup of the existing file if it exists.

  ## Parameters
  - `file_path` - Path to save the views file
  - `views` - List of view configurations
  - `opts` - Options
    - `:backup` - Create backup before overwriting (default: true)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec save_views(String.t(), [view_config()], keyword()) :: :ok | {:error, term()}
  def save_views(file_path, views, opts \\ []) do
    create_backup? = Keyword.get(opts, :backup, true)

    with {:ok, content} <- format_views(views),
         :ok <- ensure_directory(file_path),
         :ok <- maybe_create_backup(file_path, create_backup?),
         :ok <- atomic_write(file_path, content) do
      :telemetry.execute(
        [:yellow_dog, :dns, :view_store, :saved],
        %{view_count: length(views)},
        %{file_path: file_path}
      )

      :ok
    else
      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :dns, :view_store, :save_failed],
          %{count: 1},
          %{file_path: file_path, reason: inspect(reason)}
        )

        error
    end
  end

  @doc """
  Validates a view configuration.

  ## Parameters
  - `view` - View configuration map

  ## Returns
  - `:ok` if valid
  - `{:error, reason}` if invalid
  """
  @spec validate_view(map()) :: :ok | {:error, String.t()}
  def validate_view(view) do
    with :ok <- validate_required_fields(view),
         :ok <- validate_name(view.name),
         :ok <- validate_priority(view[:priority]),
         :ok <- validate_acl(view[:acl]) do
      :ok
    end
  end

  # Private functions

  defp parse_toml(content) do
    case Toml.decode(content) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:toml_parse_error, reason}}
    end
  end

  defp extract_views(data) do
    case Map.get(data, "view") do
      nil -> {:ok, []}
      views when is_list(views) -> {:ok, views}
      view when is_map(view) -> {:ok, [view]}
    end
  end

  defp validate_and_normalize_view(view) do
    normalized = normalize_view_keys(view)

    case validate_view(normalized) do
      :ok -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_view_keys(view) when is_map(view) do
    %{
      name: get_string_value(view, [:name, "name"]),
      priority: get_integer_value(view, [:priority, "priority"], 100),
      match_clients: get_string_value(view, [:match_clients, "match_clients"]),
      recursion: get_boolean_value(view, [:recursion, "recursion"], false),
      ecs_enabled: get_boolean_value(view, [:ecs_enabled, "ecs_enabled"], false),
      zones: get_list_value(view, [:zones, "zones"], []),
      acl: normalize_acl(view)
    }
  end

  defp normalize_acl(view) do
    case Map.get(view, "acl") || Map.get(view, :acl) do
      nil -> nil
      acl when is_list(acl) -> Enum.map(acl, &normalize_acl_entry/1)
      acl when is_map(acl) -> [normalize_acl_entry(acl)]
    end
  end

  defp normalize_acl_entry(entry) when is_map(entry) do
    %{
      action: get_string_value(entry, [:action, "action"], "allow"),
      network: get_string_value(entry, [:network, "network"])
    }
  end

  defp get_string_value(map, keys, default \\ nil) do
    Enum.find_value(keys, default, fn key -> Map.get(map, key) end)
  end

  defp get_integer_value(map, keys, default) do
    case Enum.find_value(keys, default, fn key -> Map.get(map, key) end) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> default
    end
  end

  defp get_boolean_value(map, keys, default) do
    case Enum.find_value(keys, default, fn key -> Map.get(map, key) end) do
      value when is_boolean(value) -> value
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp get_list_value(map, keys, default) do
    case Enum.find_value(keys, default, fn key -> Map.get(map, key) end) do
      value when is_list(value) -> value
      _ -> default
    end
  end

  defp validate_required_fields(view) do
    if is_nil(Map.get(view, :name)) do
      {:error, "Missing required field: name"}
    else
      :ok
    end
  end

  defp validate_name(name) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp validate_name(_), do: {:error, "Invalid name"}

  defp validate_priority(nil), do: :ok
  defp validate_priority(priority) when is_integer(priority) and priority >= 0, do: :ok
  defp validate_priority(_), do: {:error, "Priority must be a non-negative integer"}

  defp validate_acl(nil), do: :ok
  defp validate_acl([]), do: :ok

  defp validate_acl(acl) when is_list(acl) do
    invalid =
      Enum.reject(acl, fn entry ->
        is_map(entry) and Map.has_key?(entry, :action) and Map.has_key?(entry, :network)
      end)

    if Enum.empty?(invalid) do
      :ok
    else
      {:error, "Invalid ACL entries: #{inspect(invalid)}"}
    end
  end

  defp validate_acl(_), do: {:error, "ACL must be a list"}

  defp format_views(views) do
    header = """
    # DNS Views Configuration
    # Generated by YellowDog DNS
    #
    # Views enable split-horizon DNS - different answers for different clients
    # based on their IP addresses. Views are evaluated in order by priority.
    """

    views_content =
      views
      |> Enum.map(&view_to_toml/1)
      |> Enum.join("\n")

    {:ok, header <> "\n" <> views_content}
  end

  defp view_to_toml(view) do
    # Handle :infinity priority (used for default view) by using a large number
    priority =
      case view[:priority] do
        :infinity -> 999_999
        nil -> 100
        p when is_integer(p) -> p
        _ -> 100
      end

    lines = [
      "",
      "[[view]]",
      "name = #{encode_toml_string(view.name)}",
      "priority = #{priority}"
    ]

    lines =
      if view[:match_clients] do
        lines ++ ["match_clients = #{encode_toml_string(view.match_clients)}"]
      else
        lines
      end

    lines = lines ++ ["recursion = #{view[:recursion] || false}"]
    lines = lines ++ ["ecs_enabled = #{view[:ecs_enabled] || false}"]

    lines =
      if view[:zones] && length(view.zones) > 0 do
        # Zones may be stored as {type, name} tuples or just names
        # Convert to just names for TOML storage (type is in zones.toml)
        zone_names =
          Enum.map(view.zones, fn
            {_type, name} when is_binary(name) -> name
            name when is_binary(name) -> name
            other -> to_string(other)
          end)

        zones_str = Enum.map_join(zone_names, ", ", &encode_toml_string/1)
        lines ++ ["zones = [#{zones_str}]"]
      else
        lines
      end

    lines =
      if view[:acl] && length(view.acl) > 0 do
        acl_lines =
          Enum.flat_map(view.acl, fn acl_entry ->
            [
              "",
              "[[view.acl]]",
              "action = #{encode_toml_string(acl_entry.action)}",
              "network = #{encode_toml_string(acl_entry.network)}"
            ]
          end)

        lines ++ acl_lines
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp encode_toml_string(value) when is_binary(value) do
    "\"#{String.replace(value, "\"", "\\\"")}\""
  end

  defp encode_toml_string(value), do: inspect(value)

  defp ensure_directory(file_path) do
    dir = Path.dirname(file_path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      error -> error
    end
  end

  defp maybe_create_backup(_file_path, false), do: :ok

  defp maybe_create_backup(file_path, true) do
    if File.exists?(file_path) do
      backup_path = file_path <> ".backup"
      File.cp(file_path, backup_path)
    else
      :ok
    end
  end

  defp atomic_write(file_path, content) do
    tmp_path = file_path <> ".tmp"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, file_path) do
      :ok
    else
      error ->
        # Clean up temp file on error
        File.rm(tmp_path)
        error
    end
  end
end
