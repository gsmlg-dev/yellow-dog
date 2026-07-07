defmodule YellowDog.Netman.ProfileResolver do
  @moduledoc """
  Resolves profile-driven feature state for a `yellow_dog_netman` runtime.

  VPN support is represented only as resolved configuration state in this
  foundation layer. No tunnel implementation is started here.
  """

  alias YellowDog.ConfigHelpers
  alias YellowDog.Netman.FeatureRegistry

  @profiles [:local_server, :cloud_server, :bare_metal, :vm, :vpn_gateway, :observe_only, :custom]
  @apply_modes [:managed, :observe_first, :observe]

  @doc """
  Resolves the current `YellowDog.Config` state.
  """
  @spec resolve() :: map()
  def resolve do
    resolve(YellowDog.Config.get_all())
  end

  @doc """
  Resolves Netman feature state from a config map.
  """
  @spec resolve(map()) :: map()
  def resolve(config) when is_map(config) do
    netman_config = ConfigHelpers.get_value(config, :yellow_dog_netman, %{})
    resolve_netman_config(netman_config)
  end

  def resolve(_config), do: resolve(%{})

  @doc """
  Returns the supported Netman profile atoms.
  """
  @spec profiles() :: [atom()]
  def profiles, do: @profiles

  defp resolve_netman_config(netman_config) when is_map(netman_config) do
    profile = parse_profile(ConfigHelpers.get_value(netman_config, :profile, "custom"))
    defaults = profile_defaults(profile)
    overrides = ConfigHelpers.get_value(netman_config, :features, %{})

    %{
      id: ConfigHelpers.get_value(netman_config, :id),
      name: ConfigHelpers.get_value(netman_config, :name),
      profile: profile,
      source: :yellow_dog_netman,
      management: ConfigHelpers.get_value(netman_config, :management, %{}),
      apply_mode: resolve_apply_mode(netman_config, profile),
      features: apply_overrides(defaults, overrides)
    }
  end

  defp resolve_netman_config(_netman_config), do: resolve_netman_config(%{})

  defp parse_profile(profile) when is_atom(profile) and profile in @profiles, do: profile

  defp parse_profile(profile) when is_binary(profile) do
    profile
    |> String.to_existing_atom()
    |> parse_profile()
  rescue
    ArgumentError -> :custom
  end

  defp parse_profile(_profile), do: :custom

  defp profile_defaults(:local_server) do
    enabled_features()
    |> Map.put(:vpn, false)
  end

  defp profile_defaults(:cloud_server) do
    enabled_features()
    |> Map.put(:vpn, false)
  end

  defp profile_defaults(:bare_metal) do
    enabled_features()
    |> Map.put(:vpn, false)
  end

  defp profile_defaults(:vm) do
    enabled_features()
    |> Map.merge(%{dhcp_client: false, vpn: false})
  end

  defp profile_defaults(:vpn_gateway) do
    disabled_features()
    |> Map.merge(%{interfaces: true, dns_client: true, routes: true, link_state: true, vpn: true})
  end

  defp profile_defaults(:observe_only) do
    disabled_features()
    |> Map.merge(%{interfaces: true, link_state: true})
  end

  defp profile_defaults(:custom), do: disabled_features()

  defp enabled_features do
    Map.new(FeatureRegistry.list_features(), &{&1, true})
  end

  defp disabled_features do
    Map.new(FeatureRegistry.list_features(), &{&1, false})
  end

  defp resolve_apply_mode(netman_config, profile) do
    mode_config = ConfigHelpers.get_value(netman_config, :mode, %{})

    mode_config
    |> ConfigHelpers.get_value(:apply, default_apply_mode(profile))
    |> parse_apply_mode()
  end

  defp default_apply_mode(:cloud_server), do: :observe_first
  defp default_apply_mode(:observe_only), do: :observe
  defp default_apply_mode(_profile), do: :managed

  defp parse_apply_mode(mode) when is_atom(mode) and mode in @apply_modes, do: mode

  defp parse_apply_mode(mode) when is_binary(mode) do
    mode
    |> String.to_existing_atom()
    |> parse_apply_mode()
  rescue
    ArgumentError -> :observe_first
  end

  defp parse_apply_mode(_mode), do: :observe_first

  defp apply_overrides(defaults, overrides) when is_map(overrides) do
    Enum.reduce(FeatureRegistry.list_features(), defaults, fn feature, acc ->
      if has_config_key?(overrides, feature) do
        Map.put(acc, feature, ConfigHelpers.get_value(overrides, feature))
      else
        acc
      end
    end)
  end

  defp apply_overrides(defaults, _overrides), do: defaults

  defp has_config_key?(map, key) do
    Map.has_key?(map, key) or Map.has_key?(map, to_string(key))
  end
end
