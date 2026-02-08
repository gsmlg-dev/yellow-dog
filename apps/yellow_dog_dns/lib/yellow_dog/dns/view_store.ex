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

      # Network-based ACL
      [[view.acl]]
      action = "allow"
      network = "10.0.0.0/8"

      # Geographic ACL (by country)
      [[view.acl]]
      action = "allow"
      geo_countries = ["US", "CA", "MX"]
  """

  import YellowDog.Config.TomlHelpers,
    only: [
      parse_toml: 1,
      get_value: 2,
      get_value: 3,
      get_integer: 3,
      get_boolean: 3,
      get_list: 3,
      encode_toml_string: 1,
      ensure_directory: 1,
      maybe_create_backup: 2,
      atomic_write: 2
    ]

  @type acl_entry :: %{
          action: String.t(),
          network: String.t() | nil,
          geo_countries: [String.t()] | nil
        }

  @type view_config :: %{
          name: String.t(),
          priority: integer(),
          match_clients: String.t() | nil,
          recursion: boolean(),
          ecs_enabled: boolean(),
          zones: [String.t()],
          acl: [acl_entry()] | nil
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
        for view <- views,
            {:ok, validated} <- [validate_and_normalize_view(view)],
            do: validated

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

  defp extract_views(data) do
    case Map.get(data, "view") do
      nil -> {:ok, []}
      views when is_list(views) -> {:ok, views}
      view when is_map(view) -> {:ok, [view]}
    end
  end

  defp validate_and_normalize_view(view) do
    normalized = normalize_view_keys(view)

    with :ok <- validate_view(normalized), do: {:ok, normalized}
  end

  defp normalize_view_keys(view) when is_map(view) do
    %{
      name: get_value(view, [:name, "name"]),
      priority: get_integer(view, [:priority, "priority"], 100),
      match_clients: get_value(view, [:match_clients, "match_clients"]),
      recursion: get_boolean(view, [:recursion, "recursion"], false),
      ecs_enabled: get_boolean(view, [:ecs_enabled, "ecs_enabled"], false),
      zones: get_list(view, [:zones, "zones"], []),
      acl: normalize_acl(view)
    }
  end

  defp normalize_acl(view) do
    case get_value(view, [:acl, "acl"]) do
      nil -> nil
      acl when is_list(acl) -> Enum.map(acl, &normalize_acl_entry/1)
      acl when is_map(acl) -> [normalize_acl_entry(acl)]
    end
  end

  defp normalize_acl_entry(entry) when is_map(entry) do
    base = %{
      action: get_value(entry, [:action, "action"], "allow")
    }

    # Check if this is a geo ACL or network ACL
    geo_countries = get_list(entry, [:geo_countries, "geo_countries"], [])
    network = get_value(entry, [:network, "network"])

    cond do
      geo_countries != [] ->
        Map.put(base, :geo_countries, geo_countries)

      network != nil ->
        Map.put(base, :network, network)

      true ->
        base
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
        is_map(entry) and Map.has_key?(entry, :action) and
          (Map.has_key?(entry, :network) or Map.has_key?(entry, :geo_countries))
      end)

    if invalid == [] do
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

    views_content = Enum.map_join(views, "\n", &view_to_toml/1)

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

    base =
      [
        "",
        "[[view]]",
        "name = #{encode_toml_string(view.name)}",
        "priority = #{priority}",
        view[:match_clients] && "match_clients = #{encode_toml_string(view.match_clients)}",
        "recursion = #{view[:recursion] || false}",
        "ecs_enabled = #{view[:ecs_enabled] || false}"
      ]
      |> Enum.reject(&is_nil/1)

    zones_line =
      if view[:zones] && view.zones != [] do
        zone_names =
          Enum.map(view.zones, fn
            {_type, name} when is_binary(name) -> name
            name when is_binary(name) -> name
            other -> to_string(other)
          end)

        ["zones = [#{Enum.map_join(zone_names, ", ", &encode_toml_string/1)}]"]
      else
        []
      end

    acl_lines =
      if view[:acl] && view.acl != [] do
        Enum.flat_map(view.acl, fn acl_entry ->
          base_rule = [
            "",
            "[[view.acl]]",
            "action = #{encode_toml_string(to_string(acl_entry.action))}"
          ]

          extra =
            cond do
              Map.has_key?(acl_entry, :geo_countries) and is_list(acl_entry.geo_countries) ->
                "geo_countries = [#{Enum.map_join(acl_entry.geo_countries, ", ", &encode_toml_string/1)}]"

              Map.has_key?(acl_entry, :network) and acl_entry.network != nil ->
                "network = #{encode_toml_string(acl_entry.network)}"

              true ->
                nil
            end

          if extra, do: base_rule ++ [extra], else: base_rule
        end)
      else
        []
      end

    Enum.join(base ++ zones_line ++ acl_lines, "\n")
  end
end
