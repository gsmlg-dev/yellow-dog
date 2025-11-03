defmodule YellowDog.Dns.View.Config do
  @moduledoc """
  Configuration loader for DNS Views.

  Loads view definitions from TOML configuration files and creates View structs.

  ## Configuration Format

  Views are defined in TOML with the following structure:

      [[view]]
      name = "internal"
      match_clients = "localnets"  # Built-in ACL name
      recursion = true
      zones = ["corp.example.com", "internal.example.com"]

      [[view]]
      name = "dmz"
      recursion = true
      zones = ["dmz.example.com"]

      # Custom ACL for DMZ view
      [[view.acl]]
      action = "allow"
      network = "10.0.0.0/8"

  ## Built-in ACLs

  - `"any"` - Matches all clients
  - `"none"` - Matches no clients
  - `"localhost"` - Matches 127.0.0.1 and ::1
  - `"localnets"` - Matches RFC 1918 private networks

  ## Custom ACLs

  Custom ACLs are defined inline using `[[view.acl]]` sections:

      [[view]]
      name = "custom"
      zones = ["example.com"]

      [[view.acl]]
      action = "allow"
      network = "10.1.1.0/24"

      [[view.acl]]
      action = "deny"
      network = "10.1.0.0/16"

  ## Examples

      iex> {:ok, views} = ViewConfig.load_file("views.toml")
      iex> length(views)
      3

      iex> config = %{"view" => [%{"name" => "test", "match_clients" => "any", "zones" => []}]}
      iex> {:ok, [view]} = ViewConfig.from_map(config)
      iex> view.name
      "test"
  """

  alias YellowDog.Dns.View
  alias YellowDog.Dns.View.ACL

  @doc """
  Loads views from a TOML configuration file.

  ## Parameters

  - `path` - Path to TOML configuration file

  ## Returns

  - `{:ok, [View.t()]}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> {:ok, views} = ViewConfig.load_file("examples/views.toml")
      iex> Enum.map(views, & &1.name)
      ["internal", "dmz", "external"]
  """
  @spec load_file(String.t()) :: {:ok, [View.t()]} | {:error, term()}
  def load_file(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_toml(content)

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  @doc """
  Parses TOML content and returns views.

  ## Parameters

  - `content` - TOML configuration string

  ## Returns

  - `{:ok, [View.t()]}` on success
  - `{:error, reason}` on failure
  """
  @spec parse_toml(String.t()) :: {:ok, [View.t()]} | {:error, term()}
  def parse_toml(content) when is_binary(content) do
    case Toml.decode(content) do
      {:ok, config} ->
        from_map(config)

      {:error, reason} ->
        {:error, {:toml_parse_error, reason}}
    end
  end

  @doc """
  Converts a configuration map to a list of View structs.

  ## Parameters

  - `config` - Configuration map with "view" key containing view definitions

  ## Returns

  - `{:ok, [View.t()]}` on success
  - `{:error, reason}` on failure
  """
  @spec from_map(map()) :: {:ok, [View.t()]} | {:error, term()}
  def from_map(config) when is_map(config) do
    case Map.get(config, "view", []) do
      views when is_list(views) ->
        parse_views(views)

      _ ->
        {:error, :invalid_view_config}
    end
  end

  # Private functions

  defp parse_views(view_configs) do
    views =
      view_configs
      |> Enum.with_index()
      |> Enum.map(fn {view_config, index} ->
        parse_view(view_config, index)
      end)

    # Check for errors
    case Enum.find(views, fn result -> match?({:error, _}, result) end) do
      nil ->
        {:ok, Enum.map(views, fn {:ok, view} -> view end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_view(view_config, index) when is_map(view_config) do
    with {:ok, name} <- get_view_name(view_config, index),
         {:ok, match_clients} <- get_match_clients(view_config),
         {:ok, zones} <- get_zones(view_config),
         {:ok, recursion} <- get_recursion(view_config) do
      view = View.new(name, match_clients, zones, recursion)
      {:ok, view}
    end
  end

  defp get_view_name(config, index) do
    case Map.get(config, "name") do
      name when is_binary(name) and name != "" ->
        {:ok, name}

      _ ->
        # Generate name from index if not provided
        {:ok, "view_#{index}"}
    end
  end

  defp get_match_clients(config) do
    case {Map.get(config, "match_clients"), Map.get(config, "acl", [])} do
      {acl_name, []} when is_binary(acl_name) ->
        # Built-in ACL name
        {:ok, acl_name}

      {nil, acl_rules} when is_list(acl_rules) and acl_rules != [] ->
        # Custom ACL from inline rules
        parse_custom_acl(config["name"] || "custom", acl_rules)

      {nil, []} ->
        # No match_clients specified, default to "any"
        {:ok, :all}

      _ ->
        {:error, {:invalid_match_clients, config}}
    end
  end

  defp parse_custom_acl(name, acl_rules) do
    rules =
      acl_rules
      |> Enum.map(&parse_acl_rule/1)
      |> Enum.reject(&is_nil/1)

    if rules == [] do
      {:error, {:invalid_acl_rules, acl_rules}}
    else
      acl = ACL.new(name, rules)
      {:ok, acl}
    end
  end

  defp parse_acl_rule(rule) when is_map(rule) do
    action = parse_action(Map.get(rule, "action"))
    network = Map.get(rule, "network")

    case {action, network} do
      {nil, _} ->
        nil

      {_, nil} ->
        nil

      {act, net} when is_binary(net) ->
        # Parse CIDR string into IP tuple and prefix
        case ACL.parse_cidr(net) do
          {:ok, {ip, prefix}} -> {act, ip, prefix}
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_acl_rule(_), do: nil

  defp parse_action("allow"), do: :allow
  defp parse_action("deny"), do: :deny
  defp parse_action(_), do: nil

  defp get_zones(config) do
    case Map.get(config, "zones", []) do
      zones when is_list(zones) ->
        # Filter to only strings
        zone_list = Enum.filter(zones, &is_binary/1)
        {:ok, zone_list}

      _ ->
        {:ok, []}
    end
  end

  defp get_recursion(config) do
    case Map.get(config, "recursion_enabled") do
      true -> {:ok, true}
      false -> {:ok, false}
      nil -> {:ok, true}
      # default to true
      _ -> {:error, {:invalid_recursion, config}}
    end
  end
end
