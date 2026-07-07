defmodule YellowDog.Netman.FeatureRegistryTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netman.FeatureRegistry

  test "lists netman features in stable order" do
    assert FeatureRegistry.list_features() == [
             :interfaces,
             :dhcp_client,
             :dns_client,
             :routes,
             :link_state,
             :vpn
           ]
  end

  test "fetches feature metadata" do
    assert {:ok, metadata} = FeatureRegistry.fetch(:routes)
    assert %{name: :routes, label: "Routes"} = metadata
  end

  test "rejects unknown features without raising" do
    assert FeatureRegistry.fetch(:unknown) == :error
    refute FeatureRegistry.known?(:unknown)
  end
end
