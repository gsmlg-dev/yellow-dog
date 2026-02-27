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
      state = %CLI{socket_path: "/tmp/cli_test_nil.sock", listen_socket: nil, clients: []}
      assert {:noreply, ^state} = CLI.handle_info(:accept, state)
    end

    test "terminate/2 cleans up listen_socket and socket file" do
      # Create a real TCP listen socket to verify terminate closes it
      {:ok, listen_socket} =
        :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])

      socket_path = Path.join(System.tmp_dir!(), "cli_term_test_#{:rand.uniform(100_000)}.sock")
      File.write!(socket_path, "")
      on_exit(fn -> File.rm(socket_path) end)

      state = %CLI{socket_path: socket_path, listen_socket: listen_socket, clients: []}

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

      state = %CLI{socket_path: socket_path, listen_socket: nil, clients: []}

      # Should not raise
      CLI.terminate(:shutdown, state)
      refute File.exists?(socket_path)
    end

    test "device.show with a valid interface returns result" do
      iface = "cli_dev_show_#{:rand.uniform(100_000)}"

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
end
