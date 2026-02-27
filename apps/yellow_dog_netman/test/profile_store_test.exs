defmodule YellowDog.Netman.ProfileStoreTest do
  use ExUnit.Case

  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.Types.Profile

  setup do
    # Seed a known profile via CRUD (startup may not have loaded test profiles)
    dhcp_profile = %Profile{
      id: "test-dhcp",
      type: :ethernet,
      interface: "eth0",
      autoconnect: true,
      autoconnect_priority: 100,
      zone: "trusted",
      ethernet: %{mtu: 1500},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :auto, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put("test-dhcp", dhcp_profile)

    on_exit(fn ->
      ProfileStore.delete("test-dhcp")
      ProfileStore.delete("crud-test")
      ProfileStore.delete("delete-test")
    end)

    {:ok, dhcp_profile: dhcp_profile}
  end

  describe "profile operations" do
    test "list includes seeded profile" do
      profiles = ProfileStore.list()
      assert length(profiles) >= 1
      assert Enum.any?(profiles, &(&1.id == "test-dhcp"))
    end

    test "gets a profile by ID" do
      assert {:ok, %Profile{id: "test-dhcp"}} = ProfileStore.get("test-dhcp")
    end

    test "returns error for unknown profile" do
      assert {:error, :not_found} = ProfileStore.get("nonexistent")
    end
  end

  describe "CRUD operations" do
    test "put and get" do
      profile = %Profile{
        id: "crud-test",
        type: :ethernet,
        interface: "eth99",
        autoconnect: false
      }

      assert :ok = ProfileStore.put("crud-test", profile)
      assert {:ok, ^profile} = ProfileStore.get("crud-test")
    end

    test "delete removes profile" do
      profile = %Profile{id: "delete-test", type: :ethernet}
      ProfileStore.put("delete-test", profile)
      assert :ok = ProfileStore.delete("delete-test")
      assert {:error, :not_found} = ProfileStore.get("delete-test")
    end

    test "delete nonexistent returns error" do
      assert {:error, :not_found} = ProfileStore.delete("nonexistent")
    end
  end

  describe "match_interface/2" do
    test "matches by interface name" do
      profile = ProfileStore.match_interface("eth0")
      assert profile != nil
      assert profile.interface == "eth0"
    end

    test "returns nil for unmatched interface" do
      profile = ProfileStore.match_interface("noexist999")
      assert profile == nil
    end
  end
end
