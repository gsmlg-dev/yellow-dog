defmodule YellowDog.Netman.FeatureRegistry do
  @moduledoc """
  Registry of feature flags understood by profile-driven `yellow_dog_netman`.
  """

  @features [
    %{name: :interfaces, label: "Interfaces"},
    %{name: :dhcp_client, label: "DHCP Client"},
    %{name: :dns_client, label: "DNS Client"},
    %{name: :routes, label: "Routes"},
    %{name: :link_state, label: "Link State"},
    %{name: :vpn, label: "VPN"}
  ]

  @doc """
  Returns all feature metadata in stable order.
  """
  @spec all() :: [map()]
  def all, do: @features

  @doc """
  Returns all known feature names in stable order.
  """
  @spec list_features() :: [atom()]
  def list_features do
    Enum.map(@features, & &1.name)
  end

  @doc """
  Fetches metadata for a known feature.
  """
  @spec fetch(atom()) :: {:ok, map()} | :error
  def fetch(feature) when is_atom(feature) do
    case Enum.find(@features, &(&1.name == feature)) do
      nil -> :error
      metadata -> {:ok, metadata}
    end
  end

  def fetch(_feature), do: :error

  @doc """
  Returns true when a feature is listed in the registry.
  """
  @spec known?(term()) :: boolean()
  def known?(feature) do
    match?({:ok, _metadata}, fetch(feature))
  end
end
