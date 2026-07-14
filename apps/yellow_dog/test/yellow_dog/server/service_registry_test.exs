defmodule YellowDog.Server.ServiceRegistryTest do
  use ExUnit.Case, async: true

  alias YellowDog.Server.ServiceRegistry

  test "lists server services in stable order" do
    assert ServiceRegistry.list_services() == [
             :dns,
             :mdns,
             :dhcpv4,
             :dhcpv6,
             :netboot,
             :identity,
             :fingerprint,
             :server_agent
           ]
  end

  test "fetches metadata for known services" do
    assert {:ok, metadata} = ServiceRegistry.fetch(:dns)
    assert %{name: :dns, label: "DNS", application: :yellow_dog_dns} = metadata
    assert metadata.available? in [true, false]
  end

  test "exposes server_agent metadata safely" do
    assert {:ok, metadata} = ServiceRegistry.fetch(:server_agent)

    assert %{
             name: :server_agent,
             label: "Server Agent",
             application: :yellow_dog_server_agent,
             module: YellowDog.ServerAgent
           } = metadata

    assert metadata.available? in [true, false]
  end

  test "rejects unknown services without raising" do
    assert ServiceRegistry.fetch(:unknown) == :error
    refute ServiceRegistry.known?(:unknown)
  end
end
