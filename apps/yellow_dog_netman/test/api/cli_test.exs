defmodule YellowDog.Netman.API.CLITest do
  use ExUnit.Case

  alias YellowDog.Netman.API.CLI
  alias YellowDog.Netman.ProfileStore

  describe "handle_command/1" do
    test "status returns system status" do
      result = CLI.handle_command(%{"method" => "status"})
      assert %{"result" => status} = result
      assert is_boolean(status["running"])
      assert is_integer(status["interfaces"])
      assert is_integer(status["connections"])
      assert Map.has_key?(status, "default_route")
    end

    test "device.list returns list" do
      result = CLI.handle_command(%{"method" => "device.list"})
      assert %{"result" => devices} = result
      assert is_list(devices)
    end

    test "device is an alias for device.list" do
      result = CLI.handle_command(%{"method" => "device"})
      assert %{"result" => devices} = result
      assert is_list(devices)
    end

    test "device.show with unknown interface returns error" do
      result =
        CLI.handle_command(%{
          "method" => "device.show",
          "params" => %{"interface" => "nonexistent_iface_99"}
        })

      assert %{"error" => _} = result
    end

    test "connection.list returns list" do
      result = CLI.handle_command(%{"method" => "connection.list"})
      assert %{"result" => profiles} = result
      assert is_list(profiles)
    end

    test "connection is an alias for connection.list" do
      result = CLI.handle_command(%{"method" => "connection"})
      assert %{"result" => profiles} = result
      assert is_list(profiles)
    end

    test "connection.show with valid profile returns profile" do
      # Seed a profile
      profile = %YellowDog.Netman.Types.Profile{
        id: "cli-test-profile",
        type: :ethernet,
        interface: "eth0",
        autoconnect_priority: 100,
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :auto, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put("cli-test-profile", profile)

      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => "cli-test-profile"}
        })

      assert %{"result" => data} = result
      assert data["id"] == "cli-test-profile"
      assert data["type"] == "ethernet"
      assert data["ipv4_method"] == "auto"
    end

    test "connection.show with unknown id returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => "nonexistent-profile-99"}
        })

      assert %{"error" => _} = result
    end

    test "connection.delete with unknown id returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.delete",
          "params" => %{"id" => "nonexistent-profile-99"}
        })

      assert %{"error" => _} = result
    end

    test "connection.delete with known id returns deleted" do
      profile = %YellowDog.Netman.Types.Profile{
        id: "cli-delete-profile",
        type: :ethernet,
        interface: "eth0",
        autoconnect_priority: 100,
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :auto, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put("cli-delete-profile", profile)

      result =
        CLI.handle_command(%{
          "method" => "connection.delete",
          "params" => %{"id" => "cli-delete-profile"}
        })

      assert %{"result" => "deleted"} = result
    end

    test "connection.up with unknown id returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.up",
          "params" => %{"id" => "nonexistent-profile-up"}
        })

      assert %{"error" => _} = result
    end

    test "connection.down with unknown id returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.down",
          "params" => %{"id" => "nonexistent-profile-down"}
        })

      assert %{"error" => _} = result
    end

    test "connection.add with invalid path returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.add",
          "params" => %{"file" => "/nonexistent/path/profile.toml"}
        })

      assert %{"error" => _} = result
    end

    test "connection.add with valid TOML file imports profile" do
      toml = """
      [connection]
      id = "cli-import-test"
      type = "ethernet"
      interface = "eth99"
      autoconnect = true
      autoconnect_priority = 100

      [ipv4]
      method = "auto"

      [ipv6]
      method = "auto"
      """

      tmp_path = System.tmp_dir!() |> Path.join("cli-import-test.toml")
      File.write!(tmp_path, toml)
      on_exit(fn -> File.rm(tmp_path) end)

      result =
        CLI.handle_command(%{"method" => "connection.add", "params" => %{"file" => tmp_path}})

      assert %{"result" => "imported: cli-import-test"} = result
    end

    test "unknown method returns error" do
      result = CLI.handle_command(%{"method" => "foobar.unknown"})
      assert %{"error" => "unknown method: foobar.unknown"} = result
    end

    test "invalid command format returns error" do
      result = CLI.handle_command(%{"no_method" => true})
      assert %{"error" => "invalid command format"} = result
    end

    test "connection.up without params returns specific error" do
      result = CLI.handle_command(%{"method" => "connection.up"})
      assert %{"error" => "connection.up requires 'id' parameter"} = result
    end

    test "connection.down without params returns specific error" do
      result = CLI.handle_command(%{"method" => "connection.down"})
      assert %{"error" => "connection.down requires 'id' parameter"} = result
    end

    test "connection.add without params returns specific error" do
      result = CLI.handle_command(%{"method" => "connection.add"})
      assert %{"error" => "connection.add requires 'file' parameter"} = result
    end

    test "connection.delete without params returns specific error" do
      result = CLI.handle_command(%{"method" => "connection.delete"})
      assert %{"error" => "connection.delete requires 'id' parameter"} = result
    end
  end

  describe "GenServer handle_info" do
    test "unknown message is silently ignored" do
      pid = Process.whereis(CLI)
      assert pid != nil
      send(pid, :unexpected_cli_message)
      Process.sleep(20)
      assert Process.alive?(pid)
    end
  end

  describe "additional coverage" do
    @moduletag :capture_log

    test "handle_info(:accept, %{listen_socket: nil}) is a no-op" do
      state = %CLI{socket_path: "/tmp/cli_test_nil.sock", listen_socket: nil, active_clients: 0}
      assert {:noreply, ^state} = CLI.handle_info(:accept, state)
    end

    test "terminate/2 cleans up listen_socket and socket file" do
      # Create a real TCP listen socket to verify terminate closes it
      {:ok, listen_socket} =
        :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])

      socket_path = Path.join(System.tmp_dir!(), "cli_term_test_#{:rand.uniform(100_000)}.sock")
      File.write!(socket_path, "")
      on_exit(fn -> File.rm(socket_path) end)

      state = %CLI{socket_path: socket_path, listen_socket: listen_socket, active_clients: 0}

      CLI.terminate(:normal, state)

      # Socket should be closed (port/recv fails)
      assert {:error, _} = :gen_tcp.accept(listen_socket, 0)

      # Socket file should be removed
      refute File.exists?(socket_path)
    end

    test "terminate/2 with nil listen_socket does not crash" do
      socket_path = Path.join(System.tmp_dir!(), "cli_term_nil_#{:rand.uniform(100_000)}.sock")
      File.write!(socket_path, "")
      on_exit(fn -> File.rm(socket_path) end)

      state = %CLI{socket_path: socket_path, listen_socket: nil, active_clients: 0}

      # Should not raise
      CLI.terminate(:shutdown, state)
      refute File.exists?(socket_path)
    end

    test "device.show with a valid interface returns result" do
      iface = "cds#{:rand.uniform(9999)}"

      YellowDog.Netman.Test.MockNetlink.link_up(iface, index: 42, mac: "00:11:22:33:44:55")
      Process.sleep(50)

      result =
        CLI.handle_command(%{
          "method" => "device.show",
          "params" => %{"interface" => iface}
        })

      assert %{"result" => info} = result
      assert info.interface == iface

      # Cleanup
      YellowDog.Netman.Test.MockNetlink.link_removed(iface)
    end

    test "connection.up with a valid profile and matching interface activates" do
      iface = "cli_up_#{:rand.uniform(100_000)}"
      profile_id = "cli-up-profile-#{:rand.uniform(100_000)}"

      # Seed the interface via MockNetlink
      YellowDog.Netman.Test.MockNetlink.link_up(iface)
      Process.sleep(50)

      profile = %YellowDog.Netman.Types.Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put(profile_id, profile)
      on_exit(fn -> ProfileStore.delete(profile_id) end)

      result =
        CLI.handle_command(%{
          "method" => "connection.up",
          "params" => %{"id" => profile_id}
        })

      assert %{"result" => "activated"} = result

      # Cleanup: stop the connection FSM that was started
      YellowDog.Netman.Connection.Supervisor.stop_connection(iface)
      YellowDog.Netman.Test.MockNetlink.link_removed(iface)
    end

    test "connection.down deactivating an active connection returns deactivated" do
      iface = "cli_down_#{:rand.uniform(100_000)}"
      profile_id = "cli-down-profile-#{:rand.uniform(100_000)}"

      profile = %YellowDog.Netman.Types.Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      # Create the interface and start an FSM for it
      YellowDog.Netman.Test.MockNetlink.link_up(iface)
      Process.sleep(50)

      ProfileStore.put(profile_id, profile)
      on_exit(fn -> ProfileStore.delete(profile_id) end)

      {:ok, _pid} =
        YellowDog.Netman.Connection.Supervisor.start_connection(iface, profile)

      Process.sleep(50)

      result =
        CLI.handle_command(%{
          "method" => "connection.down",
          "params" => %{"id" => profile_id}
        })

      assert %{"result" => "deactivated"} = result

      # Cleanup
      YellowDog.Netman.Connection.Supervisor.stop_connection(iface)
      YellowDog.Netman.Test.MockNetlink.link_removed(iface)
    end
  end

  describe "monitor command" do
    test "monitor is not handled by handle_command (routed at handle_client level)" do
      # monitor is intercepted in handle_client before reaching handle_command
      result = CLI.handle_command(%{"method" => "monitor"})
      assert %{"error" => "unknown method: monitor"} = result
    end
  end

  describe "input validation" do
    test "connection.show with overly long id returns error" do
      long_id = String.duplicate("a", 200)

      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => long_id}
        })

      assert %{"error" => "identifier too long"} = result
    end

    test "connection.show with special characters in id returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => "../../etc/passwd"}
        })

      assert %{"error" => "identifier contains invalid characters"} = result
    end

    test "connection.show with empty id returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => ""}
        })

      assert %{"error" => "identifier cannot be empty"} = result
    end

    test "connection.up with invalid id returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.up",
          "params" => %{"id" => "foo bar\tbaz"}
        })

      assert %{"error" => "identifier contains invalid characters"} = result
    end

    test "connection.down with invalid id returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.down",
          "params" => %{"id" => "a\x00b"}
        })

      assert %{"error" => "identifier contains invalid characters"} = result
    end

    test "connection.delete with invalid id returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.delete",
          "params" => %{"id" => "foo/bar"}
        })

      assert %{"error" => "identifier contains invalid characters"} = result
    end

    test "device.show with interface name over 15 chars returns error" do
      result =
        CLI.handle_command(%{
          "method" => "device.show",
          "params" => %{"interface" => "this_is_way_too_long"}
        })

      assert %{"error" => "identifier too long"} = result
    end

    test "connection.add with non-toml file returns error" do
      tmp_path = Path.join(System.tmp_dir!(), "cli-test-nottoml.json")
      File.write!(tmp_path, "{}")
      on_exit(fn -> File.rm(tmp_path) end)

      result =
        CLI.handle_command(%{
          "method" => "connection.add",
          "params" => %{"file" => tmp_path}
        })

      assert %{"error" => "profile must be a .toml file"} = result
    end

    test "connection.add with path containing null byte returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.add",
          "params" => %{"file" => "/tmp/test\x00.toml"}
        })

      assert %{"error" => "path contains null byte"} = result
    end

    test "connection.add with nonexistent toml file returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.add",
          "params" => %{"file" => "/nonexistent/path.toml"}
        })

      assert %{"error" => "file not found"} = result
    end

    test "valid identifiers with hyphens and dots pass validation" do
      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => "my-profile.v2"}
        })

      # Should pass validation (returns not_found, not validation error)
      assert %{"error" => "profile not found"} = result
    end
  end

  describe "missing params edge cases" do
    test "device.show with empty params falls through to invalid command" do
      result = CLI.handle_command(%{"method" => "device.show", "params" => %{}})
      # Pattern match on %{"interface" => iface} fails, falls to catch-all
      assert %{"error" => _} = result
    end

    test "device.show without params key falls through to unknown method" do
      result = CLI.handle_command(%{"method" => "device.show"})
      # Matches %{"method" => method} catch-all since no "params"
      assert %{"error" => "unknown method: device.show"} = result
    end

    test "connection.show with empty params returns error" do
      result = CLI.handle_command(%{"method" => "connection.show", "params" => %{}})
      assert %{"error" => _} = result
    end

    test "connection.up with empty params returns error" do
      result = CLI.handle_command(%{"method" => "connection.up", "params" => %{}})
      assert %{"error" => _} = result
    end

    test "connection.down with empty params returns error" do
      result = CLI.handle_command(%{"method" => "connection.down", "params" => %{}})
      assert %{"error" => _} = result
    end

    test "connection.add with empty params returns error" do
      result = CLI.handle_command(%{"method" => "connection.add", "params" => %{}})
      assert %{"error" => _} = result
    end

    test "connection.delete with empty params returns error" do
      result = CLI.handle_command(%{"method" => "connection.delete", "params" => %{}})
      assert %{"error" => _} = result
    end

    test "params as string instead of map returns error" do
      result = CLI.handle_command(%{"method" => "device.show", "params" => "eth0"})
      assert %{"error" => _} = result
    end

    test "params as list instead of map returns error" do
      result = CLI.handle_command(%{"method" => "connection.show", "params" => ["test"]})
      assert %{"error" => _} = result
    end

    test "nil command returns invalid command format" do
      result = CLI.handle_command(nil)
      assert %{"error" => "invalid command format"} = result
    end

    test "integer command returns invalid command format" do
      result = CLI.handle_command(42)
      assert %{"error" => "invalid command format"} = result
    end
  end

  describe "identifier boundary conditions" do
    test "identifier of exactly max length (128 chars) is accepted" do
      id = String.duplicate("a", 128)

      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => id}
        })

      # Passes validation — returns not_found (not a validation error)
      assert %{"error" => "profile not found"} = result
    end

    test "identifier one over max length (129 chars) is rejected" do
      id = String.duplicate("a", 129)

      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => id}
        })

      assert %{"error" => "identifier too long"} = result
    end

    test "interface name of exactly 15 chars is accepted" do
      iface = String.duplicate("a", 15)

      result =
        CLI.handle_command(%{
          "method" => "device.show",
          "params" => %{"interface" => iface}
        })

      # Passes validation — returns interface not found
      assert %{"error" => "interface not found"} = result
    end

    test "interface name of 16 chars is rejected" do
      iface = String.duplicate("a", 16)

      result =
        CLI.handle_command(%{
          "method" => "device.show",
          "params" => %{"interface" => iface}
        })

      assert %{"error" => "identifier too long"} = result
    end

    test "unicode characters in identifier are rejected" do
      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => "café"}
        })

      assert %{"error" => "identifier contains invalid characters"} = result
    end

    test "non-string identifier returns invalid identifier" do
      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => 12345}
        })

      assert %{"error" => "invalid identifier"} = result
    end
  end

  describe "profile path edge cases" do
    test "connection.add with .TOML uppercase extension is rejected" do
      result =
        CLI.handle_command(%{
          "method" => "connection.add",
          "params" => %{"file" => "/tmp/test.TOML"}
        })

      assert %{"error" => "profile must be a .toml file"} = result
    end

    test "connection.add with path over 4096 chars is rejected" do
      long_path = "/" <> String.duplicate("a", 4092) <> ".toml"

      result =
        CLI.handle_command(%{
          "method" => "connection.add",
          "params" => %{"file" => long_path}
        })

      assert %{"error" => "path too long"} = result
    end

    test "connection.add with non-string path returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.add",
          "params" => %{"file" => 12345}
        })

      assert %{"error" => _} = result
    end

    test "connection.add with symlink is rejected" do
      real_path = Path.join(System.tmp_dir!(), "real_profile_#{:rand.uniform(100_000)}.toml")
      link_path = Path.join(System.tmp_dir!(), "link_profile_#{:rand.uniform(100_000)}.toml")

      File.write!(real_path, """
      [connection]
      id = "symlink-test"
      type = "ethernet"
      """)

      File.ln_s!(real_path, link_path)

      on_exit(fn ->
        File.rm(link_path)
        File.rm(real_path)
      end)

      result =
        CLI.handle_command(%{
          "method" => "connection.add",
          "params" => %{"file" => link_path}
        })

      assert %{"error" => "symlinks are not allowed"} = result
    end
  end
end
