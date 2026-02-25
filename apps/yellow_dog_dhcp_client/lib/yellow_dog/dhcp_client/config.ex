defmodule YellowDog.DhcpClient.Config do
  @moduledoc """
  Configuration parsing for the DHCP client.

  Reads configuration from Application env or the TOML config loaded by
  `YellowDog.Config`. Returns a structured map suitable for starting an
  `InterfaceSupervisor`.

  ## Configuration format (TOML)

      [dhcp_client]
      interface = "eth0"
      mode = "standalone"
      vendor_class = "YellowDog"
      selection_window_ms = 1000
      dad_enabled = true
      dad_probes = 3
      dad_wait_ms = 2000

      [dhcp_client.standalone]
      manage_routes = true
      manage_dns = true
      dns_method = "resolvconf"

      [dhcp_client.hook]
      backend = "networkmanager"

  Multiple interfaces are supported via named sections:

      [dhcp_client.eth0]
      mode = "standalone"

      [dhcp_client.wlan0]
      mode = "hook"
  """

  alias YellowDog.DhcpClient.OSIntegration.{HookNM, Standalone}

  require Logger

  @type mode :: :standalone | :hook
  @type dns_method :: :resolvconf | :direct | :systemd_resolved
  @type hook_backend :: :networkmanager | :systemd_networkd

  @type t :: %{
          interface: String.t(),
          mode: mode(),
          hostname: String.t() | nil,
          vendor_class: String.t(),
          selection_window_ms: pos_integer(),
          dad_enabled: boolean(),
          dad_probes: pos_integer(),
          dad_wait_ms: pos_integer(),
          standalone: %{
            manage_routes: boolean(),
            manage_dns: boolean(),
            dns_method: dns_method()
          },
          hook: %{
            backend: hook_backend()
          }
        }

  @defaults %{
    mode: :standalone,
    hostname: nil,
    vendor_class: "YellowDog",
    selection_window_ms: 1000,
    dad_enabled: true,
    dad_probes: 3,
    dad_wait_ms: 2000,
    standalone: %{
      manage_routes: true,
      manage_dns: true,
      dns_method: :resolvconf
    },
    hook: %{
      backend: :networkmanager
    }
  }

  @doc """
  Loads configuration for the given interface.

  Checks Application env first, then falls back to `YellowDog.Config` for
  TOML-sourced values. Returns a structured config map with defaults applied.

  ## Examples

      iex> YellowDog.DhcpClient.Config.load("eth0")
      %{interface: "eth0", mode: :standalone, ...}
  """
  @spec load(String.t()) :: t()
  def load(interface) when is_binary(interface) do
    raw = load_raw(interface)

    %{
      interface: interface,
      mode: parse_mode(get_in_any(raw, [:mode, "mode"], @defaults.mode)),
      hostname: get_in_any(raw, [:hostname, "hostname"], @defaults.hostname),
      vendor_class: get_in_any(raw, [:vendor_class, "vendor_class"], @defaults.vendor_class),
      selection_window_ms:
        get_in_any(
          raw,
          [:selection_window_ms, "selection_window_ms"],
          @defaults.selection_window_ms
        ),
      dad_enabled: get_in_any(raw, [:dad_enabled, "dad_enabled"], @defaults.dad_enabled),
      dad_probes: get_in_any(raw, [:dad_probes, "dad_probes"], @defaults.dad_probes),
      dad_wait_ms: get_in_any(raw, [:dad_wait_ms, "dad_wait_ms"], @defaults.dad_wait_ms),
      standalone: load_standalone(raw),
      hook: load_hook(raw)
    }
  end

  @doc """
  Loads configuration for all configured interfaces.

  Returns a map of `%{interface_name => config}`.
  """
  @spec load_all() :: %{String.t() => t()}
  def load_all do
    raw_config = load_raw_section()

    case raw_config do
      %{"interface" => iface} when is_binary(iface) ->
        # Single-interface config
        %{iface => load(iface)}

      config when is_map(config) ->
        # Multi-interface: each key that maps to a sub-map is an interface section
        config
        |> Enum.filter(fn {_k, v} -> is_map(v) and Map.has_key?(v, "mode") end)
        |> Enum.into(%{}, fn {iface, _} -> {iface, load(iface)} end)

      _ ->
        %{}
    end
  end

  @doc """
  Returns the OS integration module for the given config.

  ## Examples

      iex> config = %{mode: :standalone}
      iex> YellowDog.DhcpClient.Config.os_integration_module(config)
      YellowDog.DhcpClient.OSIntegration.Standalone

      iex> config = %{mode: :hook}
      iex> YellowDog.DhcpClient.Config.os_integration_module(config)
      YellowDog.DhcpClient.OSIntegration.HookNM
  """
  @spec os_integration_module(t() | %{mode: mode()}) :: module()
  def os_integration_module(%{mode: :standalone}), do: Standalone
  def os_integration_module(%{mode: :hook}), do: HookNM

  @doc """
  Returns the path to the TOML configuration file, if configured.
  """
  @spec config_file_path() :: String.t() | nil
  def config_file_path do
    Application.get_env(:yellow_dog_dhcp_client, :config_file) ||
      Application.get_env(:yellow_dog, :config_file)
  end

  # -- Private helpers -------------------------------------------------------

  defp load_raw(interface) do
    raw_section = load_raw_section()

    cond do
      # Named interface section: [dhcp_client.eth0]
      is_map(raw_section) and is_map(Map.get(raw_section, interface)) ->
        Map.get(raw_section, interface)

      # Top-level single-interface config: [dhcp_client] interface = "eth0"
      is_map(raw_section) ->
        raw_section

      true ->
        %{}
    end
  end

  defp load_raw_section do
    # Priority: Application env > YellowDog.Config TOML
    case Application.get_env(:yellow_dog_dhcp_client, :config) do
      nil ->
        try do
          YellowDog.Config.get("dhcp_client") || %{}
        rescue
          _ -> %{}
        end

      config when is_map(config) ->
        config

      _ ->
        %{}
    end
  end

  defp load_standalone(raw) do
    standalone_raw =
      get_in_any(raw, [:standalone, "standalone"], %{})

    standalone_raw = if is_map(standalone_raw), do: standalone_raw, else: %{}

    %{
      manage_routes:
        get_in_any(
          standalone_raw,
          [:manage_routes, "manage_routes"],
          @defaults.standalone.manage_routes
        ),
      manage_dns:
        get_in_any(standalone_raw, [:manage_dns, "manage_dns"], @defaults.standalone.manage_dns),
      dns_method:
        parse_dns_method(
          get_in_any(standalone_raw, [:dns_method, "dns_method"], @defaults.standalone.dns_method)
        )
    }
  end

  defp load_hook(raw) do
    hook_raw =
      get_in_any(raw, [:hook, "hook"], %{})

    hook_raw = if is_map(hook_raw), do: hook_raw, else: %{}

    %{
      backend:
        parse_hook_backend(get_in_any(hook_raw, [:backend, "backend"], @defaults.hook.backend))
    }
  end

  @valid_modes ~w(standalone hook)
  defp parse_mode(:standalone), do: :standalone
  defp parse_mode(:hook), do: :hook
  defp parse_mode(str) when str in @valid_modes, do: String.to_existing_atom(str)
  defp parse_mode(_), do: @defaults.mode

  @valid_dns_methods ~w(resolvconf direct systemd-resolved systemd_resolved)
  defp parse_dns_method(:resolvconf), do: :resolvconf
  defp parse_dns_method(:direct), do: :direct
  defp parse_dns_method(:systemd_resolved), do: :systemd_resolved
  defp parse_dns_method("systemd-resolved"), do: :systemd_resolved

  defp parse_dns_method(str) when str in @valid_dns_methods,
    do: String.to_existing_atom(String.replace(str, "-", "_"))

  defp parse_dns_method(_), do: @defaults.standalone.dns_method

  @valid_hook_backends ~w(networkmanager systemd-networkd systemd_networkd)
  defp parse_hook_backend(:networkmanager), do: :networkmanager
  defp parse_hook_backend(:systemd_networkd), do: :systemd_networkd
  defp parse_hook_backend("systemd-networkd"), do: :systemd_networkd

  defp parse_hook_backend(str) when str in @valid_hook_backends,
    do: String.to_existing_atom(String.replace(str, "-", "_"))

  defp parse_hook_backend(_), do: @defaults.hook.backend

  # Look up a value by trying multiple keys (atom and string variants).
  # Uses Map.has_key? so falsy values (false, 0, nil) are returned as-is
  # rather than being treated as "not found" like Enum.find_value would do.
  defp get_in_any(map, keys, default) when is_map(map) do
    case Enum.find(keys, fn key -> Map.has_key?(map, key) end) do
      nil -> default
      key -> Map.get(map, key)
    end
  end

  defp get_in_any(_, _, default), do: default
end
