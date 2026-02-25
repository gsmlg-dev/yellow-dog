defmodule YellowDog.Config.Schema do
  @moduledoc """
  Single source of truth for YellowDog configuration shape, defaults, and validation.

  Consolidates the three duplicate default definitions that previously existed in:
  - `YellowDog.Application.get_default_config/0`
  - `YellowDog.Console.ConfigManager.default_config_map/0`
  - `YellowDog.Console.ConfigManager.create_default_config/1`

  New service sections (netboot, fingerprint, etc.) can be added here and
  will automatically appear in-memory config via `merge_defaults/1`.
  """

  @doc """
  Returns the full default configuration map.

  All keys are strings to match TOML parser output.
  """
  @spec defaults() :: map()
  def defaults do
    %{
      "data_dir" => "data",
      "core" => %{
        "dns" => true,
        "mdns" => true,
        "dhcpv4" => true,
        "dhcpv6" => true
      },
      "dns" => %{
        "listen" => "0.0.0.0",
        "port" => 53
      },
      "mdns" => %{
        "listen" => "0.0.0.0",
        "port" => 5353,
        "mode" => "responder"
      },
      "dhcpv4" => %{
        "listen" => "0.0.0.0",
        "port" => 67,
        "pools" => [
          %{
            "name" => "default",
            "range_start" => "192.168.1.100",
            "range_end" => "192.168.1.200",
            "lease_time" => 3600,
            "gateway" => "192.168.1.1",
            "dns_servers" => ["8.8.8.8", "8.8.4.4"]
          }
        ]
      },
      "dhcpv6" => %{
        "listen" => "::",
        "port" => 547,
        "pools" => [
          %{
            "name" => "default",
            "range_start" => "2001:db8::100",
            "range_end" => "2001:db8::200",
            "preferred_lifetime" => 3600,
            "valid_lifetime" => 7200,
            "dns_servers" => ["2001:4860:4860::8888"]
          }
        ]
      }
    }
  end

  @doc """
  Returns a minimal configuration with all services disabled.
  """
  @spec minimal() :: map()
  def minimal do
    %{
      "core" => %{
        "dns" => false,
        "mdns" => false,
        "dhcpv4" => false,
        "dhcpv6" => false
      },
      "dns" => %{
        "listen" => "0.0.0.0",
        "port" => 53
      },
      "mdns" => %{
        "listen" => "0.0.0.0",
        "port" => 5353
      },
      "dhcpv4" => %{
        "listen" => "0.0.0.0",
        "port" => 67
      },
      "dhcpv6" => %{
        "listen" => "::",
        "port" => 547
      }
    }
  end

  @doc """
  Fills missing sections and keys with defaults. Only adds — never overwrites.

  This enables new service sections added in the schema to appear in-memory
  automatically without requiring config file changes.

  ## Examples

      iex> Schema.merge_defaults(%{"core" => %{"dns" => false}})
      %{"core" => %{"dns" => false, "mdns" => true, ...}, "dns" => %{...}, ...}
  """
  @spec merge_defaults(map()) :: map()
  def merge_defaults(config) when is_map(config) do
    deep_merge(defaults(), config)
  end

  @doc """
  Validates a configuration map.

  Checks port ranges, IP parseability, required sections, and correct types.

  ## Returns

    * `:ok` if valid
    * `{:error, errors}` where errors is a list of `{path, message}` tuples
  """
  @spec validate(map()) :: :ok | {:error, [{String.t(), String.t()}]}
  def validate(config) when is_map(config) do
    errors =
      []
      |> validate_ports(config)
      |> validate_ips(config)
      |> validate_booleans(config)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Returns section header comments for TOML generation.
  """
  @spec section_comments() :: %{String.t() => String.t()}
  def section_comments do
    %{
      "core" => "# Service enable/disable flags",
      "dns" => "# DNS server configuration",
      "mdns" => "# mDNS responder configuration",
      "dhcpv4" => "# DHCPv4 server configuration",
      "dhcpv6" => "# DHCPv6 server configuration"
    }
  end

  # Deep merge: base provides defaults, overlay wins on conflict.
  # For non-map values, overlay always wins.
  # For maps, recurse to fill missing keys.
  defp deep_merge(base, overlay) when is_map(base) and is_map(overlay) do
    Map.merge(base, overlay, fn
      _key, base_val, overlay_val when is_map(base_val) and is_map(overlay_val) ->
        deep_merge(base_val, overlay_val)

      _key, _base_val, overlay_val ->
        overlay_val
    end)
  end

  # Port validation
  @port_paths [
    {"dns.port", ["dns", "port"]},
    {"mdns.port", ["mdns", "port"]},
    {"dhcpv4.port", ["dhcpv4", "port"]},
    {"dhcpv6.port", ["dhcpv6", "port"]}
  ]

  defp validate_ports(errors, config) do
    Enum.reduce(@port_paths, errors, fn {label, path}, acc ->
      case get_in(config, path) do
        port when is_integer(port) and port >= 1 and port <= 65535 ->
          acc

        port when is_integer(port) ->
          [{label, "must be between 1 and 65535, got #{port}"} | acc]

        nil ->
          acc

        other ->
          [{label, "must be an integer, got #{inspect(other)}"} | acc]
      end
    end)
  end

  # IP address validation
  @ip_paths [
    {"dns.listen", ["dns", "listen"]},
    {"mdns.listen", ["mdns", "listen"]},
    {"dhcpv4.listen", ["dhcpv4", "listen"]},
    {"dhcpv6.listen", ["dhcpv6", "listen"]}
  ]

  defp validate_ips(errors, config) do
    Enum.reduce(@ip_paths, errors, fn {label, path}, acc ->
      case get_in(config, path) do
        ip when is_binary(ip) ->
          if parseable_ip?(ip), do: acc, else: [{label, "invalid IP address: #{ip}"} | acc]

        nil ->
          acc

        other ->
          [{label, "must be a string, got #{inspect(other)}"} | acc]
      end
    end)
  end

  # Boolean validation for core service flags
  @bool_paths [
    {"core.dns", ["core", "dns"]},
    {"core.mdns", ["core", "mdns"]},
    {"core.dhcpv4", ["core", "dhcpv4"]},
    {"core.dhcpv6", ["core", "dhcpv6"]}
  ]

  defp validate_booleans(errors, config) do
    Enum.reduce(@bool_paths, errors, fn {label, path}, acc ->
      case get_in(config, path) do
        val when is_boolean(val) -> acc
        nil -> acc
        other -> [{label, "must be a boolean, got #{inspect(other)}"} | acc]
      end
    end)
  end

  defp parseable_ip?(ip) do
    charlist = String.to_charlist(ip)

    case :inet.parse_address(charlist) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
