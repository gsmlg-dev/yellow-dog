defmodule YellowDog.Netman.API.CLICoverageTest do
  @moduledoc """
  Tests targeting uncovered branches in API.CLI:
  - handle_info(:accept, %{listen_socket: nil}) — socket creation failed
  - handle_info(:accept) when active_clients >= max_concurrent_clients
  - handle_info(:accept) with non-timeout accept error
  - init/1 mkdir_p error (lines 37-38) and listen failure (line 61)
  """
  use ExUnit.Case

  alias YellowDog.Netman.API.CLI
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Types.Profile
  alias YellowDog.Netman.Test.MockNetlink

  @moduletag :capture_log

  describe "CLI init/1 socket setup error paths" do
    setup do
      old_path = Application.get_env(:yellow_dog_netman, :socket_path)

      on_exit(fn ->
        case old_path do
          nil -> Application.delete_env(:yellow_dog_netman, :socket_path)
          path -> Application.put_env(:yellow_dog_netman, :socket_path, path)
        end
      end)

      :ok
    end

    test "mkdir_p catch-all error when socket dir component is an existing file (line 38 + 61)" do
      # Put a regular file where CLI expects a directory.
      # File.mkdir_p/1 returns {:error, :eexist} — hits the catch-all on line 38.
      # The subsequent gen_tcp.listen also fails (no such directory) — hits line 61.
      tmp_file = Path.join(System.tmp_dir!(), "cli_cov_notdir_#{:rand.uniform(65_535)}")
      File.write!(tmp_file, "existing_file")
      on_exit(fn -> File.rm(tmp_file) end)

      socket_path = "#{tmp_file}/netman.sock"
      Application.put_env(:yellow_dog_netman, :socket_path, socket_path)

      {:ok, pid} = GenServer.start_link(CLI, [])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "listen failure with socket path exceeding UNIX_PATH_MAX (line 61)" do
      # Linux UNIX_PATH_MAX = 108 bytes; paths > 107 chars cause bind to fail with :einval.
      # /tmp (5 chars) + 103 'a' chars + ".sock" (5 chars) = 113 chars > 107.
      # File.mkdir_p("/tmp") succeeds; gen_tcp.listen fails — hits line 61.
      long_name = String.duplicate("a", 103)
      socket_path = "/tmp/#{long_name}.sock"
      Application.put_env(:yellow_dog_netman, :socket_path, socket_path)

      {:ok, pid} = GenServer.start_link(CLI, [])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "mkdir_p eacces error for unwritable socket directory (line 37)" do
      # chmod 555 prevents writes by non-root users.
      # Root bypasses filesystem permissions, so we skip the assertion in that case.
      {uid_str, 0} = System.cmd("id", ["-u"])
      uid = String.trim(uid_str) |> String.to_integer()

      tmp_parent = Path.join(System.tmp_dir!(), "cli_cov_ro_#{:rand.uniform(65_535)}")
      File.mkdir_p!(tmp_parent)

      on_exit(fn ->
        File.chmod(tmp_parent, 0o755)
        File.rm_rf(tmp_parent)
      end)

      if uid == 0 do
        # Running as root — permission restrictions don't apply; line 37 untestable here.
        assert true
      else
        File.chmod!(tmp_parent, 0o555)
        socket_path = "#{tmp_parent}/sub/netman.sock"
        Application.put_env(:yellow_dog_netman, :socket_path, socket_path)

        {:ok, pid} = GenServer.start_link(CLI, [])
        assert Process.alive?(pid)
        GenServer.stop(pid)
      end
    end
  end

  describe "CLI handle_info edge cases via :sys.replace_state" do
    test "accept with closed socket triggers non-timeout error branch" do
      pid = Process.whereis(CLI)
      assert pid != nil

      original_state = :sys.get_state(pid)

      # Create and immediately close a socket — accept on it returns {:error, :closed}
      {:ok, dead_socket} =
        :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])

      :gen_tcp.close(dead_socket)

      on_exit(fn ->
        :sys.replace_state(pid, fn _state -> original_state end)
      end)

      :sys.replace_state(pid, fn state -> %{state | listen_socket: dead_socket} end)

      # Trigger :accept — gen_tcp.accept on closed socket fails with non-timeout error
      send(pid, :accept)
      Process.sleep(200)

      assert Process.alive?(pid)

      :sys.replace_state(pid, fn _state -> original_state end)
    end

    test "accept with nil listen_socket is a no-op" do
      pid = Process.whereis(CLI)
      assert pid != nil

      original_state = :sys.get_state(pid)

      # Temporarily nil the listen socket
      :sys.replace_state(pid, fn state -> %{state | listen_socket: nil} end)

      # Send :accept — should hit the nil listen_socket guard and stay alive
      send(pid, :accept)
      Process.sleep(50)

      assert Process.alive?(pid)

      # Restore original state
      :sys.replace_state(pid, fn state ->
        %{state | listen_socket: original_state.listen_socket}
      end)
    end

    test "accept when at max_concurrent_clients reschedules without crashing" do
      pid = Process.whereis(CLI)
      assert pid != nil

      original_active = :sys.get_state(pid).active_clients

      # Set active_clients to 100 (the max)
      :sys.replace_state(pid, fn state -> %{state | active_clients: 100} end)

      # Send :accept — should log warning and reschedule
      send(pid, :accept)
      Process.sleep(200)

      # Server should still be alive
      assert Process.alive?(pid)

      # Restore active_clients
      :sys.replace_state(pid, fn state -> %{state | active_clients: original_active} end)
    end

    test "DOWN message decrements active_clients" do
      pid = Process.whereis(CLI)

      original_active = :sys.get_state(pid).active_clients
      :sys.replace_state(pid, fn state -> %{state | active_clients: 5} end)

      send(pid, {:DOWN, make_ref(), :process, self(), :normal})
      Process.sleep(20)

      new_active = :sys.get_state(pid).active_clients
      assert new_active == 4

      # Restore
      :sys.replace_state(pid, fn state -> %{state | active_clients: original_active} end)
    end

    test "DOWN message does not go below 0 active_clients" do
      pid = Process.whereis(CLI)

      original_active = :sys.get_state(pid).active_clients
      :sys.replace_state(pid, fn state -> %{state | active_clients: 0} end)

      send(pid, {:DOWN, make_ref(), :process, self(), :normal})
      Process.sleep(20)

      new_active = :sys.get_state(pid).active_clients
      assert new_active == 0

      :sys.replace_state(pid, fn state -> %{state | active_clients: original_active} end)
    end

    test "unknown messages are silently ignored by CLI GenServer" do
      pid = Process.whereis(CLI)
      send(pid, {:unknown_cli_message, :test})
      Process.sleep(20)
      assert Process.alive?(pid)
    end
  end

  describe "CLI handle_command error paths" do
    test "device.show with valid but not-found interface returns error" do
      result =
        CLI.handle_command(%{
          "method" => "device.show",
          "params" => %{"interface" => "nosuchiface_cov_#{:rand.uniform(65535)}"}
        })

      assert %{"error" => _} = result
    end

    test "connection.show with non-existent profile returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => "nosuchprofile-cov-#{:rand.uniform(65535)}"}
        })

      assert %{"error" => _} = result
    end

    test "connection.up with non-existent profile returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.up",
          "params" => %{"id" => "nosuchprofile-up-#{:rand.uniform(65535)}"}
        })

      assert %{"error" => _} = result
    end

    test "connection.down with non-existent profile returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.down",
          "params" => %{"id" => "nosuchprofile-down-#{:rand.uniform(65535)}"}
        })

      assert %{"error" => _} = result
    end

    test "connection.add with non-existent file path returns error" do
      profile_dir = Application.get_env(:yellow_dog_netman, :profile_dir)

      result =
        CLI.handle_command(%{
          "method" => "connection.add",
          "params" => %{"file" => Path.join(profile_dir, "nonexistent_cov.toml")}
        })

      assert %{"error" => _} = result
    end

    test "connection.delete with non-existent profile returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.delete",
          "params" => %{"id" => "nonexistent-del-cov"}
        })

      assert %{"error" => _} = result
    end

    test "unknown method returns error" do
      result = CLI.handle_command(%{"method" => "nonexistent.command"})
      assert %{"error" => _} = result
    end

    test "connection.add with valid file but invalid profile data returns error" do
      # Create a temp .toml file with valid TOML syntax but missing required 'id' field
      profile_dir = Application.get_env(:yellow_dog_netman, :profile_dir)
      tmp_path = Path.join(profile_dir, "invalid_profile_#{:rand.uniform(65535)}.toml")

      File.write!(tmp_path, """
      [connection]
      type = "ethernet"
      """)

      on_exit(fn -> File.rm(tmp_path) end)

      # validate_profile_path passes (file exists, .toml, not symlink)
      # import_profile fails (missing id) → {:error, reason} hits line 285
      result =
        CLI.handle_command(%{"method" => "connection.add", "params" => %{"file" => tmp_path}})

      assert %{"error" => _} = result
    end
  end

  describe "status command with active connection" do
    test "status returns default_route as profile_id string when connection exists" do
      iface = "cli_cov_stat_#{:rand.uniform(65535)}"
      profile_id = "cli-cov-stat-#{iface}"

      profile = %Profile{
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
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
      Process.sleep(100)

      # With at least one connection, PolicyEngine.default_route returns {:ok, id} → line 373
      result = CLI.handle_command(%{"method" => "status"})
      assert %{"result" => status_with} = result
      assert is_binary(status_with["default_route"])

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "status returns nil default_route when no connections are running" do
      # Deterministically stop all active connections so list_connections() returns [],
      # causing PolicyEngine.default_route([]) → :none → format_system_status L374 → nil.
      for %{interface: iface} <- Connection.Supervisor.list_connections(), is_binary(iface) do
        Connection.Supervisor.stop_connection(iface)
      end

      result = CLI.handle_command(%{"method" => "status"})
      assert %{"result" => status} = result
      assert is_nil(status["default_route"])
    end
  end
end
