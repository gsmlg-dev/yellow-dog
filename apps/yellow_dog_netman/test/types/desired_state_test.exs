defmodule YellowDog.Netman.Types.DesiredStateTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netman.Types.{DesiredState, Profile}

  test "from_profiles/1 creates desired state from profile-interface pairs" do
    profile = %Profile{
      id: "test-eth",
      type: :ethernet,
      interface: "eth0",
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: 1500},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: ["8.8.8.8"]},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    desired = DesiredState.from_profiles([{profile, "eth0"}])
    assert Map.has_key?(desired.connections, "test-eth")

    conn = desired.connections["test-eth"]
    assert conn.profile_id == "test-eth"
    assert conn.interface == "eth0"
    assert conn.mtu == 1500
    assert conn.priority == 100
    assert conn.dns == ["8.8.8.8"]
  end

  test "from_profiles/1 with empty list" do
    desired = DesiredState.from_profiles([])
    assert desired.connections == %{}
  end

  test "from_profiles/1 with multiple profiles" do
    p1 = %Profile{
      id: "eth0-profile",
      type: :ethernet,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :auto, address: nil, gateway: nil, dns: []}
    }

    p2 = %Profile{
      id: "eth1-profile",
      type: :ethernet,
      autoconnect_priority: 50,
      ethernet: %{mtu: 9000},
      ipv4: %{method: :manual, address: "10.0.0.1/24", gateway: "10.0.0.1", dns: ["10.0.0.1"]},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    desired = DesiredState.from_profiles([{p1, "eth0"}, {p2, "eth1"}])
    assert map_size(desired.connections) == 2
    assert desired.connections["eth0-profile"].priority == 100
    assert desired.connections["eth1-profile"].priority == 50
  end
end
