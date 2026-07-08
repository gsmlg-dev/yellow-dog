defmodule YellowDog.Server.ProfileResolver do
  @moduledoc """
  Resolves profile-driven service state for a `yellow_dog_server` runtime.

  New `[yellow_dog_server]` config is preferred. If it is absent, the resolver
  mirrors the legacy `[core]` service flag behavior so migration can happen
  without changing `YellowDog.Config.service_enabled?/1`.
  """

  alias YellowDog.ConfigHelpers
  alias YellowDog.Server.ServiceRegistry

  @profiles [:cloud_dns, :local_network, :dns_only, :dhcp_only, :netboot_only, :custom]
  @legacy_services [:dns, :mdns, :dhcpv4, :dhcpv6, :netboot, :identity]

  @doc """
  Resolves the current `YellowDog.Config` state.
  """
  @spec resolve() :: map()
  def resolve do
    resolve(YellowDog.Config.get_all())
  end

  @doc """
  Resolves server service state from a config map.
  """
  @spec resolve(map()) :: map()
  def resolve(config) when is_map(config) do
    case ConfigHelpers.get_value(config, :yellow_dog_server) do
      server_config when is_map(server_config) ->
        resolve_server_config(server_config)

      _ ->
        resolve_legacy_core(config)
    end
  end

  def resolve(_config), do: resolve(%{})

  @doc """
  Returns the supported server profile atoms.
  """
  @spec profiles() :: [atom()]
  def profiles, do: @profiles

  defp resolve_server_config(server_config) do
    profile = parse_profile(ConfigHelpers.get_value(server_config, :profile, "custom"))
    defaults = profile_defaults(profile)
    overrides = ConfigHelpers.get_value(server_config, :services, %{})

    %{
      id: ConfigHelpers.get_value(server_config, :id),
      name: ConfigHelpers.get_value(server_config, :name),
      profile: profile,
      source: :yellow_dog_server,
      management: ConfigHelpers.get_value(server_config, :management, %{}),
      services: apply_overrides(defaults, overrides)
    }
  end

  defp resolve_legacy_core(config) do
    core_config = ConfigHelpers.get_value(config, :core, %{})

    %{
      id: nil,
      name: nil,
      profile: :custom,
      source: :legacy_core,
      management: %{},
      services: legacy_services(core_config)
    }
  end

  defp parse_profile(profile) when is_atom(profile) and profile in @profiles, do: profile

  defp parse_profile(profile) when is_binary(profile) do
    profile
    |> String.to_existing_atom()
    |> parse_profile()
  rescue
    ArgumentError -> :custom
  end

  defp parse_profile(_profile), do: :custom

  defp profile_defaults(:cloud_dns) do
    disabled_services()
    |> Map.merge(%{dns: true, server_agent: true})
  end

  defp profile_defaults(:local_network) do
    Map.new(ServiceRegistry.list_services(), &{&1, true})
  end

  defp profile_defaults(:dns_only) do
    disabled_services()
    |> Map.merge(%{dns: true, server_agent: true})
  end

  defp profile_defaults(:dhcp_only) do
    disabled_services()
    |> Map.merge(%{dhcpv4: true, dhcpv6: true, server_agent: true})
  end

  defp profile_defaults(:netboot_only) do
    disabled_services()
    |> Map.merge(%{netboot: true, server_agent: true})
  end

  defp profile_defaults(:custom), do: disabled_services()

  defp disabled_services do
    Map.new(ServiceRegistry.list_services(), &{&1, false})
  end

  defp legacy_services(core_config) when is_map(core_config) do
    Map.new(ServiceRegistry.list_services(), fn service ->
      {service, ConfigHelpers.get_value(core_config, service, legacy_default_enabled?(service))}
    end)
  end

  defp legacy_services(_core_config) do
    Map.new(ServiceRegistry.list_services(), &{&1, legacy_default_enabled?(&1)})
  end

  defp legacy_default_enabled?(:netboot), do: false
  defp legacy_default_enabled?(service) when service in @legacy_services, do: true
  defp legacy_default_enabled?(_service), do: false

  defp apply_overrides(defaults, overrides) when is_map(overrides) do
    Enum.reduce(ServiceRegistry.list_services(), defaults, fn service, acc ->
      if has_config_key?(overrides, service) do
        Map.put(acc, service, boolean_override(overrides, service))
      else
        acc
      end
    end)
  end

  defp apply_overrides(defaults, _overrides), do: defaults

  defp has_config_key?(map, key) do
    Map.has_key?(map, key) or Map.has_key?(map, to_string(key))
  end

  defp boolean_override(map, key) do
    case ConfigHelpers.get_value(map, key) do
      value when is_boolean(value) -> value
      _value -> false
    end
  end
end
