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

  describe "hot-reload via file_event" do
    test "profile is updated when file_event is received for modified TOML" do
      # Write a temp TOML file and simulate a hot-reload file event
      tmp_dir = System.tmp_dir!()
      tmp_file = Path.join(tmp_dir, "hotreload_test_#{:rand.uniform(65535)}.toml")

      toml_content = """
      [connection]
      id = "hotreload-test-profile"
      type = "ethernet"
      interface = "eth99"
      autoconnect = true
      autoconnect_priority = 200

      [ipv4]
      method = "manual"
      address = "192.168.5.10/24"
      gateway = "192.168.5.1"

      [ipv6]
      method = "disabled"
      """

      File.write!(tmp_file, toml_content)

      # Subscribe to profile change events before triggering the reload
      YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

      # Simulate the file_event that FileSystem would send
      send(ProfileStore, {:file_event, self(), {tmp_file, [:modified]}})
      Process.sleep(100)

      # Profile should now be in the store
      assert {:ok, profile} = ProfileStore.get("hotreload-test-profile")
      assert profile.interface == "eth99"
      assert profile.autoconnect_priority == 200
      assert profile.ipv4.method == :manual

      # EventBus should have received a :reloaded notification
      assert_receive {:netman_event, "netman:profile:changed",
                      {:reloaded, "hotreload-test-profile"}},
                     500

      # Cleanup
      File.rm(tmp_file)
      ProfileStore.delete("hotreload-test-profile")
    end

    test "non-TOML file events are ignored" do
      # Subscribe first to confirm no spurious events
      YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

      send(ProfileStore, {:file_event, self(), {"/tmp/somefile.txt", [:modified]}})
      Process.sleep(100)

      # Should not receive a profile:changed event for non-TOML
      refute_receive {:netman_event, "netman:profile:changed", _}, 200
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

  describe "EventBus events" do
    test "put publishes :updated event" do
      YellowDog.Netman.EventBus.subscribe("netman:profile:changed")
      profile = %Profile{id: "event-put-test", type: :ethernet}
      ProfileStore.put("event-put-test", profile)

      assert_receive {:netman_event, "netman:profile:changed", {:updated, "event-put-test"}}, 500

      ProfileStore.delete("event-put-test")
    end

    test "import_file publishes :added event" do
      YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

      toml = """
      [connection]
      id = "event-import-test"
      type = "ethernet"
      interface = "eth0"

      [ipv4]
      method = "auto"

      [ipv6]
      method = "auto"
      """

      tmp_path = System.tmp_dir!() |> Path.join("event-import-test.toml")
      File.write!(tmp_path, toml)
      on_exit(fn -> File.rm(tmp_path) end)

      ProfileStore.import_file(tmp_path)

      assert_receive {:netman_event, "netman:profile:changed", {:added, "event-import-test"}}, 500

      ProfileStore.delete("event-import-test")
    end

    test "file_event :stop is handled gracefully" do
      send(ProfileStore, {:file_event, self(), :stop})
      Process.sleep(50)
      # No crash - the watcher_pid is set to nil
      assert Process.alive?(Process.whereis(ProfileStore))
    end

    test "handle_info with unknown message is silently ignored" do
      pid = Process.whereis(ProfileStore)
      send(pid, :some_unexpected_profile_store_msg)
      Process.sleep(20)
      assert Process.alive?(pid)
    end

    test "reload error when TOML is invalid logs warning and keeps state" do
      tmp_file = System.tmp_dir!() |> Path.join("invalid_#{:rand.uniform(65535)}.toml")
      File.write!(tmp_file, "not valid toml {{ broken\n")
      on_exit(fn -> File.rm(tmp_file) end)

      existing_count = length(ProfileStore.list())
      send(ProfileStore, {:file_event, self(), {tmp_file, [:modified]}})
      Process.sleep(100)

      assert Process.alive?(Process.whereis(ProfileStore))
      assert length(ProfileStore.list()) == existing_count
    end

    test "delete publishes :deleted event" do
      YellowDog.Netman.EventBus.subscribe("netman:profile:changed")
      profile = %Profile{id: "event-del-test", type: :ethernet}
      ProfileStore.put("event-del-test", profile)
      # Drain the :updated event
      assert_receive {:netman_event, "netman:profile:changed", {:updated, "event-del-test"}}, 500

      ProfileStore.delete("event-del-test")
      assert_receive {:netman_event, "netman:profile:changed", {:deleted, "event-del-test"}}, 500
    end
  end

  describe "import_file/1" do
    test "import_file with nonexistent file returns file_read error" do
      result = ProfileStore.import_file("/nonexistent/path/profile.toml")
      assert {:error, {:file_read, :enoent}} = result
    end

    test "import_file with invalid TOML returns toml_parse error" do
      tmp_path = System.tmp_dir!() |> Path.join("bad_import_#{:rand.uniform(65535)}.toml")
      File.write!(tmp_path, "{{invalid toml")
      on_exit(fn -> File.rm(tmp_path) end)

      result = ProfileStore.import_file(tmp_path)
      assert {:error, {:toml_parse, _}} = result
    end
  end

  describe "match_interface/2 priority ordering" do
    test "prefers exact interface match over wildcard" do
      unique_iface = "prio_eth_#{:rand.uniform(65535)}"

      exact = %Profile{
        id: "exact-match-#{unique_iface}",
        type: :ethernet,
        interface: unique_iface,
        autoconnect_priority: 50
      }

      wildcard = %Profile{
        id: "wildcard-match-#{unique_iface}",
        type: :ethernet,
        interface: nil,
        autoconnect_priority: 200
      }

      ProfileStore.put(exact.id, exact)
      ProfileStore.put(wildcard.id, wildcard)

      on_exit(fn ->
        ProfileStore.delete(exact.id)
        ProfileStore.delete(wildcard.id)
      end)

      profile = ProfileStore.match_interface(unique_iface)
      assert profile.id == exact.id
    end

    test "match_interface with non-ethernet type" do
      wifi = %Profile{id: "wifi-test", type: :wifi, interface: "wlan0"}
      ProfileStore.put("wifi-test", wifi)
      on_exit(fn -> ProfileStore.delete("wifi-test") end)

      profile = ProfileStore.match_interface("wlan0", :wifi)
      assert profile != nil
      assert profile.id == "wifi-test"
    end
  end

  describe "file_event edge cases" do
    test "non-modified events on TOML files are ignored" do
      YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

      send(ProfileStore, {:file_event, self(), {"/tmp/test.toml", [:created]}})
      Process.sleep(100)

      refute_receive {:netman_event, "netman:profile:changed", _}, 200
    end
  end
end
