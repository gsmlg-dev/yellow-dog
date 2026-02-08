defmodule YellowDog.Dhcpv4.ACL do
  @moduledoc """
  Access Control List (ACL) enforcement for DHCPv4.

  Evaluates ACL rules in priority order (lowest first) to determine
  client access, pool assignment, and custom option application.

  ## Rule Types

  - **MAC-based**: Match by MAC address pattern
  - **Vendor Class**: Match by DHCP option 60 (vendor class identifier)
  - **User Class**: Match by DHCP option 77 (user class)
  - **Client Architecture**: Match by DHCP option 93 (client architecture)

  ## Actions

  - `allow` - Allow access to specified pool
  - `deny` - Deny access entirely
  - `custom_options` - Apply custom option set

  ## Configuration Format

      [[rules]]
      priority = 10
      type = "mac"
      pattern = "aa:bb:cc:*"
      action = "allow"
      target_pool = "office_network"
  """

  require Logger

  @type mac_address :: binary()
  @type action :: :allow | :deny | :custom_options
  @type rule_type :: :mac | :vendor_class | :user_class | :client_arch

  @type rule :: %{
          priority: non_neg_integer(),
          type: rule_type(),
          pattern: String.t(),
          action: action(),
          target_pool: String.t() | nil,
          option_set: String.t() | nil
        }

  @type client_info :: %{
          mac_address: mac_address(),
          vendor_class: String.t() | nil,
          user_class: String.t() | nil,
          client_arch: non_neg_integer() | nil
        }

  @type match_result ::
          {:allow, String.t() | nil}
          | {:deny, String.t()}
          | {:custom_options, String.t()}
          | :no_match

  @default_policy :allow

  @doc """
  Loads ACL rules from a TOML file.

  ## Parameters
  - `path` - Path to TOML configuration file

  ## Returns
  - `{:ok, [rule()]}` - Successfully loaded rules (sorted by priority)
  - `{:error, reason}` - Failed to load or parse
  """
  @spec load(String.t()) :: {:ok, [rule()]} | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, config} ->
            parse_rules(config)

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
  Loads ACL rules with fallback to empty list.

  ## Parameters
  - `path` - Path to TOML configuration file

  ## Returns
  - List of rules (sorted by priority)
  """
  @spec load_with_fallback(String.t()) :: [rule()]
  def load_with_fallback(path) do
    case load(path) do
      {:ok, rules} -> rules
      {:error, _reason} -> []
    end
  end

  @doc """
  Evaluates ACL rules against client information.

  Rules are evaluated in priority order (lowest first).
  First matching rule determines the action.

  ## Parameters
  - `rules` - List of ACL rules
  - `client_info` - Client information map
  - `default_policy` - Policy if no rules match (`:allow` or `:deny`)

  ## Returns
  - `{:allow, pool_name}` - Allow access, optionally with pool assignment
  - `{:deny, reason}` - Deny access
  - `{:custom_options, option_set_name}` - Apply custom options
  """
  @spec evaluate([rule()], client_info(), :allow | :deny) :: match_result()
  def evaluate(rules, client_info, default_policy \\ @default_policy) do
    sorted_rules = Enum.sort_by(rules, & &1.priority)

    result =
      Enum.find_value(sorted_rules, fn rule ->
        if matches_rule?(rule, client_info) do
          apply_rule_action(rule)
        else
          nil
        end
      end)

    case result do
      nil ->
        emit_no_match_telemetry(client_info)

        case default_policy do
          :allow -> {:allow, nil}
          :deny -> {:deny, "no matching ACL rule"}
        end

      match_result ->
        emit_match_telemetry(client_info, match_result)
        match_result
    end
  end

  @doc """
  Checks if a client is allowed access based on ACL rules.

  ## Parameters
  - `rules` - List of ACL rules
  - `client_info` - Client information map

  ## Returns
  - `true` if access is allowed
  - `false` if access is denied
  """
  @spec allowed?([rule()], client_info()) :: boolean()
  def allowed?(rules, client_info) do
    case evaluate(rules, client_info) do
      {:allow, _} -> true
      {:custom_options, _} -> true
      {:deny, _} -> false
      :no_match -> true
    end
  end

  @doc """
  Gets the target pool for a client based on ACL rules.

  ## Parameters
  - `rules` - List of ACL rules
  - `client_info` - Client information map

  ## Returns
  - Pool name if ACL specifies one
  - `nil` if no pool assignment
  """
  @spec get_target_pool([rule()], client_info()) :: String.t() | nil
  def get_target_pool(rules, client_info) do
    case evaluate(rules, client_info) do
      {:allow, pool_name} -> pool_name
      _ -> nil
    end
  end

  @doc """
  Gets the custom option set for a client based on ACL rules.

  ## Parameters
  - `rules` - List of ACL rules
  - `client_info` - Client information map

  ## Returns
  - Option set name if ACL specifies custom options
  - `nil` if no custom options
  """
  @spec get_option_set([rule()], client_info()) :: String.t() | nil
  def get_option_set(rules, client_info) do
    case evaluate(rules, client_info) do
      {:custom_options, option_set} -> option_set
      _ -> nil
    end
  end

  @doc """
  Validates an ACL rule configuration.

  ## Parameters
  - `rule_config` - Raw rule configuration map from TOML

  ## Returns
  - `{:ok, rule()}` - Valid rule
  - `{:error, reason}` - Validation failed
  """
  @spec validate_rule(map()) :: {:ok, rule()} | {:error, term()}
  def validate_rule(rule_config) do
    with {:ok, priority} <- validate_priority(rule_config),
         {:ok, type} <- validate_type(rule_config),
         {:ok, pattern} <- validate_pattern(rule_config),
         {:ok, action} <- validate_action(rule_config) do
      rule = %{
        priority: priority,
        type: type,
        pattern: pattern,
        action: action,
        target_pool: Map.get(rule_config, "target_pool"),
        option_set: Map.get(rule_config, "option_set")
      }

      {:ok, rule}
    end
  end

  # Private functions

  defp parse_rules(%{"rules" => rules}) when is_list(rules) do
    results =
      Enum.map(rules, &validate_rule/1)

    case collect_ok(results) do
      {:ok, rules} ->
        emit_loaded_telemetry(length(rules))
        {:ok, rules}

      {:error, errors} ->
        {:error, {:validation_errors, errors}}
    end
  end

  defp parse_rules(_config) do
    {:ok, []}
  end

  defp validate_priority(rule_config) do
    case Map.get(rule_config, "priority") do
      nil -> {:error, :missing_priority}
      priority when is_integer(priority) and priority >= 0 -> {:ok, priority}
      _ -> {:error, :invalid_priority}
    end
  end

  defp validate_type(rule_config) do
    case Map.get(rule_config, "type") do
      "mac" -> {:ok, :mac}
      "vendor_class" -> {:ok, :vendor_class}
      "user_class" -> {:ok, :user_class}
      "client_arch" -> {:ok, :client_arch}
      nil -> {:error, :missing_type}
      _ -> {:error, :invalid_type}
    end
  end

  defp validate_pattern(rule_config) do
    case Map.get(rule_config, "pattern") do
      nil -> {:error, :missing_pattern}
      pattern when is_binary(pattern) -> {:ok, pattern}
      _ -> {:error, :invalid_pattern}
    end
  end

  defp validate_action(rule_config) do
    case Map.get(rule_config, "action") do
      "allow" -> {:ok, :allow}
      "deny" -> {:ok, :deny}
      "custom_options" -> {:ok, :custom_options}
      nil -> {:error, :missing_action}
      _ -> {:error, :invalid_action}
    end
  end

  defp matches_rule?(rule, client_info) do
    case rule.type do
      :mac ->
        match_pattern(rule.pattern, format_mac(client_info.mac_address))

      :vendor_class ->
        match_pattern(rule.pattern, client_info.vendor_class || "")

      :user_class ->
        match_pattern(rule.pattern, client_info.user_class || "")

      :client_arch ->
        match_pattern(rule.pattern, to_string(client_info.client_arch || ""))
    end
  end

  defp match_pattern(pattern, value) do
    # Convert glob pattern to regex
    regex_pattern =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    case Regex.compile("^#{regex_pattern}$", "i") do
      {:ok, regex} ->
        value =~ regex

      {:error, _} ->
        false
    end
  end

  defp apply_rule_action(rule) do
    case rule.action do
      :allow -> {:allow, rule.target_pool}
      :deny -> {:deny, "denied by ACL rule"}
      :custom_options -> {:custom_options, rule.option_set}
    end
  end

  defp format_mac(mac) when is_binary(mac) do
    YellowDog.Dhcpv4.MacFormat.format(mac) || String.upcase(mac)
  end

  defp format_mac(_), do: ""

  defp collect_ok(results) do
    {oks, errors} = Enum.split_with(results, &match?({:ok, _}, &1))

    if errors == [] do
      {:ok, Enum.map(oks, fn {:ok, val} -> val end)}
    else
      {:error, errors}
    end
  end

  # Telemetry helpers

  defp emit_error_telemetry(path, reason, error) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :acl, :error],
      %{count: 1},
      %{path: path, reason: reason, error: inspect(error)}
    )
  end

  defp emit_loaded_telemetry(count) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :acl, :loaded],
      %{rule_count: count},
      %{}
    )
  end

  defp emit_match_telemetry(client_info, result) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :acl, :match],
      %{count: 1},
      %{
        client_mac: format_mac(client_info.mac_address),
        result: inspect(result)
      }
    )
  end

  defp emit_no_match_telemetry(client_info) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :acl, :no_match],
      %{count: 1},
      %{client_mac: format_mac(client_info.mac_address)}
    )
  end
end
