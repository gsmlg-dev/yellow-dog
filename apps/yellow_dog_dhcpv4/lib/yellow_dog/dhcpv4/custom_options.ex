defmodule YellowDog.Dhcpv4.CustomOptions do
  @moduledoc """
  Custom DHCP option management with template variable support.

  Loads option sets from TOML configuration and applies them based on
  scope hierarchy:
  1. Static reservation options (highest priority)
  2. ACL-matched option sets
  3. Pool-level options
  4. Global options (lowest priority)

  ## Template Variables

  Simple `${var}` substitution is supported:
  - `${client_mac}` - Client MAC address
  - `${client_hostname}` - Requested hostname
  - `${lease_address}` - Assigned IP address
  - `${pool_name}` - Pool identifier

  No expression evaluation or conditionals - missing variables are
  replaced with empty string.

  ## Configuration Format

      [[option_sets]]
      name = "windows_clients"
      scope = "acl"

      [[option_sets.options]]
      code = 42
      type = "ip_list"
      value = ["192.168.1.10", "192.168.1.11"]

      [[option_sets.options]]
      code = 66
      type = "string"
      value = "tftp-${pool_name}.local"
  """

  require Logger

  alias YellowDog.Dhcpv4.{AddressPool, Ipv4Util}

  @type ip_address :: AddressPool.ip_address()
  @type mac_address :: binary()

  @type option_type :: :string | :ip | :ip_list | :uint8 | :uint16 | :uint32 | :hex

  @type option_definition :: %{
          code: 1..254,
          type: option_type(),
          value: term()
        }

  @type option_set :: %{
          name: String.t(),
          scope: :global | :pool | :acl | :reservation,
          options: [option_definition()]
        }

  @type template_context :: %{
          client_mac: mac_address() | nil,
          client_hostname: String.t() | nil,
          lease_address: ip_address() | nil,
          pool_name: String.t() | nil
        }

  @doc """
  Loads option sets from a TOML file.

  ## Parameters
  - `path` - Path to TOML configuration file

  ## Returns
  - `{:ok, [option_set()]}` - Successfully loaded option sets
  - `{:error, reason}` - Failed to load or parse
  """
  @spec load(String.t()) :: {:ok, [option_set()]} | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, config} ->
            parse_option_sets(config)

          {:error, reason} ->
            emit_error_telemetry(path, :parse_error, reason)
            {:error, {:parse_error, reason}}
        end

      {:error, reason} ->
        emit_error_telemetry(path, :read_error, reason)
        {:error, {:read_error, reason}}
    end
  end

  @doc """
  Loads option sets with fallback to empty list.

  ## Parameters
  - `path` - Path to TOML configuration file

  ## Returns
  - List of option sets
  """
  @spec load_with_fallback(String.t()) :: [option_set()]
  def load_with_fallback(path) do
    case load(path) do
      {:ok, option_sets} -> option_sets
      {:error, _reason} -> []
    end
  end

  @doc """
  Gets an option set by name.

  ## Parameters
  - `option_sets` - List of option sets
  - `name` - Option set name

  ## Returns
  - `{:ok, option_set()}` - Found
  - `{:error, :not_found}` - Not found
  """
  @spec get_option_set([option_set()], String.t()) :: {:ok, option_set()} | {:error, :not_found}
  def get_option_set(option_sets, name) do
    case Enum.find(option_sets, fn set -> set.name == name end) do
      nil -> {:error, :not_found}
      set -> {:ok, set}
    end
  end

  @doc """
  Applies template variables to option values.

  ## Parameters
  - `option_set` - Option set to process
  - `context` - Template context with variable values

  ## Returns
  - Option set with variables substituted
  """
  @spec apply_templates(option_set(), template_context()) :: option_set()
  def apply_templates(option_set, context) do
    processed_options =
      Enum.map(option_set.options, fn option ->
        case option.type do
          :string ->
            %{option | value: substitute_variables(option.value, context)}

          _ ->
            option
        end
      end)

    %{option_set | options: processed_options}
  end

  @doc """
  Merges multiple option sets with priority (later sets override earlier).

  ## Parameters
  - `option_sets` - List of option sets in priority order (lowest to highest)
  - `context` - Template context for variable substitution

  ## Returns
  - List of merged option definitions with templates applied
  """
  @spec merge_option_sets([option_set()], template_context()) :: [option_definition()]
  def merge_option_sets(option_sets, context) do
    # Apply templates and flatten all options; later sets override earlier (Map.new keeps last)
    option_sets
    |> Enum.flat_map(fn set -> apply_templates(set, context).options end)
    |> Map.new(fn opt -> {opt.code, opt} end)
    |> Map.values()
  end

  @doc """
  Encodes options to DHCP wire format.

  ## Parameters
  - `options` - List of option definitions

  ## Returns
  - List of DHCPv4.Message.Option structs
  """
  @spec encode_options([option_definition()]) :: [map()]
  def encode_options(options) do
    Enum.map(options, fn opt ->
      case encode_option(opt) do
        {:ok, encoded} -> encoded
        {:error, _reason} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Validates an option definition.

  ## Parameters
  - `option_config` - Raw option configuration from TOML

  ## Returns
  - `{:ok, option_definition()}` - Valid option
  - `{:error, reason}` - Validation failed
  """
  @spec validate_option(map()) :: {:ok, option_definition()} | {:error, term()}
  def validate_option(option_config) do
    with {:ok, code} <- validate_option_code(option_config),
         {:ok, type} <- validate_option_type(option_config),
         {:ok, value} <- validate_option_value(option_config, type) do
      {:ok, %{code: code, type: type, value: value}}
    end
  end

  # Private functions

  defp parse_option_sets(%{"option_sets" => sets}) when is_list(sets) do
    results =
      Enum.map(sets, fn set_config ->
        validate_option_set(set_config)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      option_sets = Enum.map(results, fn {:ok, set} -> set end)
      emit_loaded_telemetry(length(option_sets))
      {:ok, option_sets}
    else
      {:error, {:validation_errors, errors}}
    end
  end

  defp parse_option_sets(_config) do
    {:ok, []}
  end

  defp validate_option_set(set_config) do
    with {:ok, name} <- validate_set_name(set_config),
         {:ok, scope} <- validate_set_scope(set_config),
         {:ok, options} <- validate_set_options(set_config) do
      {:ok, %{name: name, scope: scope, options: options}}
    end
  end

  defp validate_set_name(config) do
    case Map.get(config, "name") do
      nil -> {:error, :missing_name}
      name when is_binary(name) -> {:ok, name}
      _ -> {:error, :invalid_name}
    end
  end

  defp validate_set_scope(config) do
    case Map.get(config, "scope", "global") do
      "global" -> {:ok, :global}
      "pool" -> {:ok, :pool}
      "acl" -> {:ok, :acl}
      "reservation" -> {:ok, :reservation}
      _ -> {:error, :invalid_scope}
    end
  end

  defp validate_set_options(config) do
    case Map.get(config, "options", []) do
      options when is_list(options) ->
        results = Enum.map(options, &validate_option/1)
        errors = Enum.filter(results, &match?({:error, _}, &1))

        if Enum.empty?(errors) do
          {:ok, Enum.map(results, fn {:ok, opt} -> opt end)}
        else
          {:error, {:invalid_options, errors}}
        end

      _ ->
        {:error, :invalid_options}
    end
  end

  defp validate_option_code(config) do
    case Map.get(config, "code") do
      nil -> {:error, :missing_code}
      code when is_integer(code) and code >= 1 and code <= 254 -> {:ok, code}
      _ -> {:error, :invalid_code}
    end
  end

  defp validate_option_type(config) do
    case Map.get(config, "type") do
      "string" -> {:ok, :string}
      "ip" -> {:ok, :ip}
      "ip_list" -> {:ok, :ip_list}
      "uint8" -> {:ok, :uint8}
      "uint16" -> {:ok, :uint16}
      "uint32" -> {:ok, :uint32}
      "hex" -> {:ok, :hex}
      nil -> {:error, :missing_type}
      _ -> {:error, :invalid_type}
    end
  end

  defp validate_option_value(config, type) do
    value = Map.get(config, "value")

    case {type, value} do
      {_, nil} ->
        {:error, :missing_value}

      {:string, v} when is_binary(v) ->
        {:ok, v}

      {:ip, v} when is_binary(v) ->
        parse_ip(v)

      {:ip_list, v} when is_list(v) ->
        parse_ip_list(v)

      {:uint8, v} when is_integer(v) and v >= 0 and v <= 255 ->
        {:ok, v}

      {:uint16, v} when is_integer(v) and v >= 0 and v <= 65535 ->
        {:ok, v}

      {:uint32, v} when is_integer(v) and v >= 0 and v <= 4_294_967_295 ->
        {:ok, v}

      {:hex, v} when is_binary(v) ->
        parse_hex(v)

      _ ->
        {:error, {:invalid_value, type, value}}
    end
  end

  defp parse_ip(ip_str) do
    case Ipv4Util.parse(ip_str) do
      {:ok, ip_tuple} -> {:ok, ip_tuple}
      {:error, _} -> {:error, {:invalid_ip, ip_str}}
    end
  end

  defp parse_ip_list(ip_strs) do
    results = Enum.map(ip_strs, &parse_ip/1)
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, ip} -> ip end)}
    else
      {:error, {:invalid_ip_list, errors}}
    end
  end

  defp parse_hex(hex_str) do
    # Remove optional "0x" prefix
    clean_str = String.replace_prefix(hex_str, "0x", "")

    case Base.decode16(clean_str, case: :mixed) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, {:invalid_hex, hex_str}}
    end
  end

  defp substitute_variables(template, context) when is_binary(template) do
    template
    |> String.replace("${client_mac}", format_mac(context[:client_mac]))
    |> String.replace("${client_hostname}", context[:client_hostname] || "")
    |> String.replace("${lease_address}", format_ip(context[:lease_address]))
    |> String.replace("${pool_name}", context[:pool_name] || "")
  end

  defp substitute_variables(value, _context), do: value

  defp encode_option(%{code: code, type: type, value: value}) do
    case encode_value(type, value) do
      {:ok, binary} ->
        {:ok,
         %DHCPv4.Message.Option{
           type: code,
           length: byte_size(binary),
           value: binary
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode_value(:string, value) when is_binary(value) do
    {:ok, value}
  end

  defp encode_value(:ip, {a, b, c, d}) do
    {:ok, <<a, b, c, d>>}
  end

  defp encode_value(:ip_list, ips) when is_list(ips) do
    binary = Enum.map_join(ips, fn {a, b, c, d} -> <<a, b, c, d>> end)

    {:ok, binary}
  end

  defp encode_value(:uint8, value) when is_integer(value) do
    {:ok, <<value::8>>}
  end

  defp encode_value(:uint16, value) when is_integer(value) do
    {:ok, <<value::16>>}
  end

  defp encode_value(:uint32, value) when is_integer(value) do
    {:ok, <<value::32>>}
  end

  defp encode_value(:hex, value) when is_binary(value) do
    {:ok, value}
  end

  defp encode_value(type, value) do
    {:error, {:encode_failed, type, value}}
  end

  defp format_mac(nil), do: ""
  defp format_mac(mac) when is_binary(mac), do: YellowDog.Dhcpv4.MacFormat.format(mac) || mac

  defp format_ip(ip), do: Ipv4Util.format(ip) || ""

  # Telemetry helpers

  defp emit_error_telemetry(path, reason, error) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :custom_options, :error],
      %{count: 1},
      %{path: path, reason: reason, error: inspect(error)}
    )
  end

  defp emit_loaded_telemetry(count) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :custom_options, :loaded],
      %{option_set_count: count},
      %{}
    )
  end
end
