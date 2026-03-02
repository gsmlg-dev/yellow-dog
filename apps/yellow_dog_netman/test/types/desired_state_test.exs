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

  test "from_profiles/1 concatenates DNS from both IPv4 and IPv6" do
    profile = %Profile{
      id: "dual-dns",
      type: :ethernet,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: ["8.8.8.8", "8.8.4.4"]},
      ipv6: %{method: :auto, address: nil, gateway: nil, dns: ["2001:4860:4860::8888"]}
    }

    desired = DesiredState.from_profiles([{profile, "eth0"}])
    conn = desired.connections["dual-dns"]
    assert conn.dns == ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888"]
  end

  test "from_profiles/1 handles nil DNS fields gracefully" do
    profile = %Profile{
      id: "nil-dns",
      type: :ethernet,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: nil},
      ipv6: %{method: :auto, address: nil, gateway: nil, dns: nil}
    }

    desired = DesiredState.from_profiles([{profile, "eth0"}])
    conn = desired.connections["nil-dns"]
    assert conn.dns == []
  end

  test "from_profiles/1 handles mixed nil and populated DNS" do
    profile = %Profile{
      id: "mixed-dns",
      type: :ethernet,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: nil},
      ipv6: %{method: :auto, address: nil, gateway: nil, dns: ["2001:4860:4860::8844"]}
    }

    desired = DesiredState.from_profiles([{profile, "eth0"}])
    conn = desired.connections["mixed-dns"]
    assert conn.dns == ["2001:4860:4860::8844"]
  end

  test "from_profiles/1 with duplicate profile IDs, last one wins" do
    p1 = %Profile{
      id: "shared-id",
      type: :ethernet,
      autoconnect_priority: 100,
      ethernet: %{mtu: 1500},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: ["8.8.8.8"]},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    p2 = %Profile{
      id: "shared-id",
      type: :ethernet,
      autoconnect_priority: 200,
      ethernet: %{mtu: 9000},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: ["1.1.1.1"]},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    desired = DesiredState.from_profiles([{p1, "eth0"}, {p2, "eth1"}])
    # Duplicate key: last entry wins in `for ... into: %{}`
    assert map_size(desired.connections) == 1
    conn = desired.connections["shared-id"]
    assert conn.interface == "eth1"
    assert conn.priority == 200
    assert conn.mtu == 9000
  end

  test "from_profiles/1 preserves DNS ordering (IPv4 before IPv6)" do
    profile = %Profile{
      id: "dns-order",
      type: :ethernet,
      autoconnect_priority: 0,
      ethernet: %{mtu: nil},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: ["1.1.1.1", "8.8.8.8"]},
      ipv6: %{method: :auto, address: nil, gateway: nil, dns: ["2606:4700:4700::1111"]}
    }

    desired = DesiredState.from_profiles([{profile, "eth0"}])
    conn = desired.connections["dns-order"]
    assert conn.dns == ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"]
  end
end
