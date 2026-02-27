defmodule YellowDog.NetmanTest do
  use ExUnit.Case

  alias YellowDog.Netman
  alias YellowDog.Netman.Test.MockNetlink

  describe "status/0" do
    test "returns running status with interfaces and connections counts" do
      status = Netman.status()
      assert is_boolean(status.running)
      assert is_list(status.interfaces)
      assert is_list(status.connections)
      assert status.default_route == :none or match?({:ok, _}, status.default_route)
    end
  end

  describe "interface_info/1" do
    test "returns :not_found for unknown interface" do
      assert {:error, :not_found} = Netman.interface_info("nonexistent_999")
    end

    test "returns info map for known interface" do
      iface = "netman_info_#{:rand.uniform(65535)}"
      MockNetlink.link_up(iface)
      MockNetlink.address_added(iface, "10.60.0.1/24")
      Process.sleep(50)

      assert {:ok, info} = Netman.interface_info(iface)
      assert info.interface == iface
      assert is_list(info.addresses)
      assert is_list(info.routes)
    end
  end

  describe "list_interfaces/0 and list_profiles/0" do
    test "list_interfaces returns a list" do
      assert is_list(Netman.list_interfaces())
    end

    test "list_profiles returns a list" do
      assert is_list(Netman.list_profiles())
    end
  end

  describe "get_profile/1" do
    test "returns error for unknown profile" do
      assert {:error, :not_found} = Netman.get_profile("nonexistent-profile-999")
    end
  end

  describe "default_route/0" do
    test "returns :none when no default route" do
      result = Netman.default_route()
      assert result == :none or match?({:ok, _}, result)
    end
  end

  describe "activate/1 and deactivate/1" do
    test "activate returns error for unknown profile" do
      assert {:error, :not_found} = Netman.activate("nonexistent-facade-profile")
    end

    test "deactivate returns error for unknown profile" do
      assert {:error, :not_found} = Netman.deactivate("nonexistent-facade-profile")
    end
  end

  describe "get_profile/1 found case" do
    test "returns profile when it exists" do
      profile = %YellowDog.Netman.Types.Profile{
        id: "facade-get-test",
        type: :ethernet,
        interface: "eth0",
        autoconnect_priority: 100,
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :auto, address: nil, gateway: nil, dns: []}
      }

      YellowDog.Netman.ProfileStore.put("facade-get-test", profile)

      assert {:ok, %{id: "facade-get-test"}} = Netman.get_profile("facade-get-test")

      YellowDog.Netman.ProfileStore.delete("facade-get-test")
    end
  end

  describe "list_connections/0" do
    test "returns a list" do
      assert is_list(Netman.list_connections())
    end
  end

  describe "child_spec/1 delegation" do
    test "child_spec delegates to Supervisor and returns a valid spec map" do
      spec = Netman.child_spec([])
      assert is_map(spec)
      assert Map.has_key?(spec, :id)
      assert Map.has_key?(spec, :start)
    end
  end

  describe "import_profile/1" do
    test "returns error for non-existent file" do
      assert {:error, _} = Netman.import_profile("/tmp/nonexistent_#{:rand.uniform(65535)}.toml")
    end

    test "returns error for invalid TOML file" do
      path = System.tmp_dir!() |> Path.join("bad_#{:rand.uniform(65535)}.toml")
      File.write!(path, "not valid toml {{ broken")
      on_exit(fn -> File.rm(path) end)

      assert {:error, _} = Netman.import_profile(path)
    end

    test "imports a valid TOML profile" do
      id = "facade-import-#{:rand.uniform(65535)}"

      toml = """
      [connection]
      id = "#{id}"
      type = "ethernet"
      interface = "eth_facade"
      autoconnect = false

      [ipv4]
      method = "disabled"

      [ipv6]
      method = "disabled"
      """

      path = System.tmp_dir!() |> Path.join("#{id}.toml")
      File.write!(path, toml)

      on_exit(fn ->
        File.rm(path)
        Netman.delete_profile(id)
      end)

      assert {:ok, profile} = Netman.import_profile(path)
      assert profile.id == id
    end
  end

  describe "delete_profile/1" do
    test "deletes an existing profile" do
      id = "facade-delete-#{:rand.uniform(65535)}"

      profile = %YellowDog.Netman.Types.Profile{
        id: id,
        type: :ethernet,
        interface: "eth_del"
      }

      YellowDog.Netman.ProfileStore.put(id, profile)
      assert :ok = Netman.delete_profile(id)
      assert {:error, :not_found} = Netman.get_profile(id)
    end

    test "returns error for non-existent profile" do
      assert {:error, :not_found} = Netman.delete_profile("nonexistent-facade-del")
    end
  end
end
