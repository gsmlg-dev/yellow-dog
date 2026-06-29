defmodule YellowDog.Netman.Security.HardeningTest do
  @moduledoc """
  Security-focused tests for input validation and resource limits.
  """
  use ExUnit.Case

  alias YellowDog.Netman.API.CLI
  alias YellowDog.Netman.ProfileStore

  @moduletag :capture_log

  describe "ProfileStore file size limit" do
    test "parse_toml_file rejects files larger than 1MB" do
      tmp_dir = System.tmp_dir!() |> Path.join("ps_size_#{:rand.uniform(65535)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      # Create a file just over 1MB with padding comment
      large_content =
        """
        [connection]
        id = "large-file-test"
        type = "ethernet"
        [ipv4]
        method = "auto"
        [ipv6]
        method = "auto"
        """ <> String.duplicate("# padding\n", 120_000)

      assert byte_size(large_content) > 1_048_576

      large_path = Path.join(tmp_dir, "large.toml")
      File.write!(large_path, large_content)

      old_env = Application.get_env(:yellow_dog_netman, :profile_dir)
      Application.put_env(:yellow_dog_netman, :profile_dir, tmp_dir)

      on_exit(fn ->
        if old_env do
          Application.put_env(:yellow_dog_netman, :profile_dir, old_env)
        else
          Application.delete_env(:yellow_dog_netman, :profile_dir)
        end
      end)

      # Start an isolated ProfileStore to test loading
      {:ok, test_pid} = GenServer.start_link(ProfileStore, [])
      on_exit(fn -> if Process.alive?(test_pid), do: GenServer.stop(test_pid, :normal) end)

      # The large file should be skipped during load
      profiles = GenServer.call(test_pid, :list)
      refute Enum.any?(profiles, &(&1.id == "large-file-test"))
    end

    test "parse_toml_file accepts files at exactly 1MB" do
      tmp_dir = System.tmp_dir!() |> Path.join("ps_ok_#{:rand.uniform(65535)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      base_content = """
      [connection]
      id = "ok-size-test"
      type = "ethernet"
      [ipv4]
      method = "auto"
      [ipv6]
      method = "auto"
      """

      # Pad to just under 1MB
      target = 1_048_576 - byte_size(base_content) - 1
      padded = base_content <> String.duplicate("#", target) <> "\n"
      assert byte_size(padded) <= 1_048_576

      ok_path = Path.join(tmp_dir, "ok.toml")
      File.write!(ok_path, padded)

      old_env = Application.get_env(:yellow_dog_netman, :profile_dir)
      Application.put_env(:yellow_dog_netman, :profile_dir, tmp_dir)

      on_exit(fn ->
        if old_env do
          Application.put_env(:yellow_dog_netman, :profile_dir, old_env)
        else
          Application.delete_env(:yellow_dog_netman, :profile_dir)
        end
      end)

      {:ok, test_pid} = GenServer.start_link(ProfileStore, [])
      on_exit(fn -> if Process.alive?(test_pid), do: GenServer.stop(test_pid, :normal) end)

      profiles = GenServer.call(test_pid, :list)
      assert Enum.any?(profiles, &(&1.id == "ok-size-test"))
    end
  end

  describe "CLI method field type safety" do
    test "non-string method field is handled as invalid command" do
      # Valid JSON but method is an integer
      result = CLI.handle_command(%{"method" => 123})
      assert %{"error" => _} = result
    end

    test "nil method field is handled as invalid command" do
      result = CLI.handle_command(%{"method" => nil})
      assert %{"error" => _} = result
    end

    test "list method field is handled as invalid command" do
      result = CLI.handle_command(%{"method" => ["status"]})
      assert %{"error" => _} = result
    end

    test "map method field is handled as invalid command" do
      result = CLI.handle_command(%{"method" => %{"name" => "status"}})
      assert %{"error" => _} = result
    end

    test "boolean method field is handled as invalid command" do
      result = CLI.handle_command(%{"method" => true})
      assert %{"error" => _} = result
    end
  end

  describe "CLI TCP non-string method via socket" do
    @describetag :network
    @describetag :integration

    defp connect_to_cli do
      socket_path = :sys.get_state(CLI).socket_path

      :gen_tcp.connect({:local, String.to_charlist(socket_path)}, 0, [
        :binary,
        packet: :line,
        active: false
      ])
    end

    test "JSON with integer method returns error over socket" do
      {:ok, socket} = connect_to_cli()
      :gen_tcp.send(socket, ~s({"method": 123}\n))
      {:ok, response_line} = :gen_tcp.recv(socket, 0, 2000)
      :gen_tcp.close(socket)

      {:ok, response} = Jason.decode(response_line)
      assert %{"error" => _} = response
    end

    test "JSON with null method returns error over socket" do
      {:ok, socket} = connect_to_cli()
      :gen_tcp.send(socket, ~s({"method": null}\n))
      {:ok, response_line} = :gen_tcp.recv(socket, 0, 2000)
      :gen_tcp.close(socket)

      {:ok, response} = Jason.decode(response_line)
      assert %{"error" => _} = response
    end

    test "empty JSON object returns error over socket" do
      {:ok, socket} = connect_to_cli()
      :gen_tcp.send(socket, "{}\n")
      {:ok, response_line} = :gen_tcp.recv(socket, 0, 2000)
      :gen_tcp.close(socket)

      {:ok, response} = Jason.decode(response_line)
      assert %{"error" => "invalid command format"} = response
    end

    test "JSON array returns error over socket" do
      {:ok, socket} = connect_to_cli()
      :gen_tcp.send(socket, ~s([{"method": "status"}]\n))
      {:ok, response_line} = :gen_tcp.recv(socket, 0, 2000)
      :gen_tcp.close(socket)

      {:ok, response} = Jason.decode(response_line)
      assert %{"error" => "invalid command format"} = response
    end
  end

  describe "CLI backpressure" do
    test "active_clients at max delays accept" do
      pid = Process.whereis(CLI)

      # Save original state
      original_state = :sys.get_state(pid)

      # Temporarily set active_clients to 100 (the max)
      :sys.replace_state(pid, fn state -> %{state | active_clients: 100} end)

      # Send an accept message — should log warning and delay
      send(pid, :accept)
      Process.sleep(50)

      # Engine should still be alive
      assert Process.alive?(pid)

      # Restore original state
      :sys.replace_state(pid, fn state ->
        %{state | active_clients: original_state.active_clients}
      end)
    end
  end
end
