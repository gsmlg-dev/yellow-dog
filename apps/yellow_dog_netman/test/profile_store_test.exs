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
      # Wait for debounce timer (200ms) to flush pending reloads
      Process.sleep(300)

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

    test "multiple rapid file events are debounced into a single reload" do
      tmp_dir = System.tmp_dir!()
      tmp_file = Path.join(tmp_dir, "debounce_test_#{:rand.uniform(65535)}.toml")

      toml_content = """
      [connection]
      id = "debounce-test-profile"
      type = "ethernet"
      interface = "eth98"
      autoconnect = false

      [ipv4]
      method = "disabled"

      [ipv6]
      method = "disabled"
      """

      File.write!(tmp_file, toml_content)
      on_exit(fn -> File.rm(tmp_file) end)

      YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

      # Send 5 rapid file events (simulating editor save behavior)
      for _ <- 1..5 do
        send(ProfileStore, {:file_event, self(), {tmp_file, [:modified]}})
      end

      # Wait for debounce to flush
      Process.sleep(400)

      # Should receive exactly one reload event, not five
      assert_receive {:netman_event, "netman:profile:changed",
                      {:reloaded, "debounce-test-profile"}},
                     500

      refute_receive {:netman_event, "netman:profile:changed",
                      {:reloaded, "debounce-test-profile"}},
                     200

      ProfileStore.delete("debounce-test-profile")
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

    test "file_event :stop is handled gracefully and logs warning" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          send(ProfileStore, {:file_event, self(), :stop})
          Process.sleep(50)
        end)

      assert Process.alive?(Process.whereis(ProfileStore))
      assert log =~ "watcher stopped"
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
      # Wait for debounce timer (200ms) to flush pending reloads
      Process.sleep(300)

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

    test "symlink TOML files are ignored during hot-reload" do
      tmp_dir = System.tmp_dir!()
      target = Path.join(tmp_dir, "reload_target_#{:rand.uniform(65535)}.toml")
      link = Path.join(tmp_dir, "reload_link_#{:rand.uniform(65535)}.toml")

      File.write!(target, """
      [connection]
      id = "reload-symlink-test"
      type = "ethernet"
      [ipv4]
      method = "auto"
      [ipv6]
      method = "auto"
      """)

      File.ln_s!(target, link)

      on_exit(fn ->
        File.rm(link)
        File.rm(target)
      end)

      YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

      send(ProfileStore, {:file_event, self(), {link, [:modified]}})
      Process.sleep(100)

      # Symlink should be ignored — no profile change event
      refute_receive {:netman_event, "netman:profile:changed", _}, 200
      assert {:error, :not_found} = ProfileStore.get("reload-symlink-test")
    end
  end

  describe "import_file edge cases" do
    test "import_file with valid TOML but invalid profile returns error" do
      # TOML that parses but fails Profile.from_toml validation (missing id)
      toml = """
      [connection]
      type = "ethernet"
      """

      tmp_path = System.tmp_dir!() |> Path.join("no_id_#{:rand.uniform(65535)}.toml")
      File.write!(tmp_path, toml)
      on_exit(fn -> File.rm(tmp_path) end)

      result = ProfileStore.import_file(tmp_path)
      assert {:error, _} = result
    end
  end

  describe "import_file path validation" do
    test "import_file rejects non-.toml extension" do
      tmp_path = Path.join(System.tmp_dir!(), "profile_#{:rand.uniform(65535)}.json")
      File.write!(tmp_path, "{}")
      on_exit(fn -> File.rm(tmp_path) end)

      assert {:error, :invalid_path} = ProfileStore.import_file(tmp_path)
    end

    test "import_file rejects path with null byte" do
      assert {:error, :invalid_path} = ProfileStore.import_file("/tmp/test\x00.toml")
    end

    test "import_file rejects extremely long path" do
      long_path = "/" <> String.duplicate("a", 5000) <> ".toml"
      assert {:error, :invalid_path} = ProfileStore.import_file(long_path)
    end

    test "import_file rejects symlinks" do
      tmp_dir = System.tmp_dir!()
      target = Path.join(tmp_dir, "symlink_target_#{:rand.uniform(65535)}.toml")
      link = Path.join(tmp_dir, "symlink_link_#{:rand.uniform(65535)}.toml")

      File.write!(target, """
      [connection]
      id = "symlink-test"
      type = "ethernet"
      [ipv4]
      method = "auto"
      [ipv6]
      method = "auto"
      """)

      File.ln_s!(target, link)

      on_exit(fn ->
        File.rm(link)
        File.rm(target)
      end)

      assert {:error, :invalid_path} = ProfileStore.import_file(link)
    end
  end

  describe "handle_info catch-all" do
    test "unknown messages are ignored without crashing" do
      send(ProfileStore, {:unknown_message_type, :test_data})
      Process.sleep(50)

      assert {:ok, %Profile{}} = ProfileStore.get("test-dhcp")
    end
  end

  describe "match_interface priority ordering" do
    test "exact interface match is preferred over wildcard profile" do
      exact_id = "match-exact-#{:rand.uniform(65535)}"
      wild_id = "match-wild-#{:rand.uniform(65535)}"

      exact_profile = %Profile{
        id: exact_id,
        type: :ethernet,
        interface: "eth_match_exact",
        autoconnect: true,
        autoconnect_priority: 50
      }

      wildcard_profile = %Profile{
        id: wild_id,
        type: :ethernet,
        interface: nil,
        autoconnect: true,
        autoconnect_priority: 200
      }

      ProfileStore.put(exact_id, exact_profile)
      ProfileStore.put(wild_id, wildcard_profile)

      on_exit(fn ->
        ProfileStore.delete(exact_id)
        ProfileStore.delete(wild_id)
      end)

      matched = ProfileStore.match_interface("eth_match_exact", :ethernet)
      assert matched != nil
      assert matched.id == exact_id
    end

    test "wildcard profile matches any interface when no exact match" do
      wild_id = "match-any-#{:rand.uniform(65535)}"

      wildcard_profile = %Profile{
        id: wild_id,
        type: :ethernet,
        interface: nil,
        autoconnect: true,
        autoconnect_priority: 100
      }

      ProfileStore.put(wild_id, wildcard_profile)
      on_exit(fn -> ProfileStore.delete(wild_id) end)

      matched = ProfileStore.match_interface("eth_unique_#{:rand.uniform(65535)}", :ethernet)
      assert matched != nil
      assert matched.id == wild_id
    end

    test "returns nil when no profile matches interface type" do
      matched = ProfileStore.match_interface("eth_no_wifi_#{:rand.uniform(65535)}", :wifi)
      assert matched == nil
    end

    test "highest priority wildcard profile wins when multiple wildcards exist" do
      lo_id = "match-wild-lo-#{:rand.uniform(65535)}"
      hi_id = "match-wild-hi-#{:rand.uniform(65535)}"

      lo_profile = %Profile{
        id: lo_id,
        type: :ethernet,
        interface: nil,
        autoconnect: true,
        autoconnect_priority: 50
      }

      hi_profile = %Profile{
        id: hi_id,
        type: :ethernet,
        interface: nil,
        autoconnect: true,
        autoconnect_priority: 300
      }

      ProfileStore.put(lo_id, lo_profile)
      ProfileStore.put(hi_id, hi_profile)

      on_exit(fn ->
        ProfileStore.delete(lo_id)
        ProfileStore.delete(hi_id)
      end)

      matched =
        ProfileStore.match_interface("eth_multi_wild_#{:rand.uniform(65535)}", :ethernet)

      assert matched != nil
      assert matched.id == hi_id
    end
  end

  describe "profile ID change on hot-reload" do
    test "old profile ID is removed when TOML file changes its connection.id" do
      tmp_dir = System.tmp_dir!()
      tmp_file = Path.join(tmp_dir, "id_change_test_#{:rand.uniform(65535)}.toml")

      # Write initial TOML with ID "old-id"
      File.write!(tmp_file, """
      [connection]
      id = "id-change-old"
      type = "ethernet"
      interface = "eth_idchg"

      [ipv4]
      method = "auto"

      [ipv6]
      method = "disabled"
      """)

      on_exit(fn ->
        File.rm(tmp_file)
        ProfileStore.delete("id-change-old")
        ProfileStore.delete("id-change-new")
      end)

      YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

      # First load: creates "id-change-old"
      send(ProfileStore, {:file_event, self(), {tmp_file, [:modified]}})
      Process.sleep(300)

      assert {:ok, %Profile{id: "id-change-old"}} = ProfileStore.get("id-change-old")

      # Drain events
      assert_receive {:netman_event, "netman:profile:changed",
                      {:reloaded, "id-change-old"}}, 500

      # Now change the ID in the file
      File.write!(tmp_file, """
      [connection]
      id = "id-change-new"
      type = "ethernet"
      interface = "eth_idchg"

      [ipv4]
      method = "auto"

      [ipv6]
      method = "disabled"
      """)

      send(ProfileStore, {:file_event, self(), {tmp_file, [:modified]}})
      Process.sleep(300)

      # Old ID should be deleted, new ID should exist
      assert {:error, :not_found} = ProfileStore.get("id-change-old")
      assert {:ok, %Profile{id: "id-change-new"}} = ProfileStore.get("id-change-new")

      # Should receive a :deleted event for old ID and :reloaded for new ID
      assert_receive {:netman_event, "netman:profile:changed",
                      {:deleted, "id-change-old"}}, 500
      assert_receive {:netman_event, "netman:profile:changed",
                      {:reloaded, "id-change-new"}}, 500
    end
  end
end
