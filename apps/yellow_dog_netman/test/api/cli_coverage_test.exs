defmodule YellowDog.Netman.API.CLICoverageTest do
  @moduledoc """
  Tests targeting uncovered branches in API.CLI:
  - handle_info(:accept, %{listen_socket: nil}) — socket creation failed
  - handle_info(:accept) when active_clients >= max_concurrent_clients
  - handle_info(:accept) with non-timeout accept error
  - monitor_loop keepalive after 30s (skipped — impractical timeout)
  """
  use ExUnit.Case

  alias YellowDog.Netman.API.CLI

  @moduletag :capture_log

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

    test "client_done decrements active_clients" do
      pid = Process.whereis(CLI)

      original_active = :sys.get_state(pid).active_clients
      :sys.replace_state(pid, fn state -> %{state | active_clients: 5} end)

      send(pid, :client_done)
      Process.sleep(20)

      new_active = :sys.get_state(pid).active_clients
      assert new_active == 4

      # Restore
      :sys.replace_state(pid, fn state -> %{state | active_clients: original_active} end)
    end

    test "client_done does not go below 0 active_clients" do
      pid = Process.whereis(CLI)

      original_active = :sys.get_state(pid).active_clients
      :sys.replace_state(pid, fn state -> %{state | active_clients: 0} end)

      send(pid, :client_done)
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
      result =
        CLI.handle_command(%{
          "method" => "connection.add",
          "params" => %{"file" => "/nonexistent/path/profile_cov.toml"}
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
  end
end
