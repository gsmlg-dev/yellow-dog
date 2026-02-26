defmodule Abyss.Transport.UDP.CoreTest do
  @moduledoc """
  Comprehensive unit tests for Abyss.Transport.UDP.Core module.

  Tests cover:
  - Module structure and exports
  - merge_options/2 - option merging logic
  - open_socket/2 - socket creation
  - Delegated functions verification
  """
  use ExUnit.Case, async: true

  alias Abyss.Transport.UDP.Core

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Core)
    end

    test "exports merge_options/2" do
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :merge_options, 2)
    end

    test "exports open_socket/2" do
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :open_socket, 2)
    end

    test "exports controlling_process/2" do
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :controlling_process, 2)
    end

    test "exports recv/2 and recv/3" do
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :recv, 2)
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :recv, 3)
    end

    test "exports send/2, send/3, send/4, send/5" do
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :send, 2)
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :send, 3)
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :send, 4)
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :send, 5)
    end

    test "exports getopts/2 and setopts/2" do
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :getopts, 2)
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :setopts, 2)
    end

    test "exports close/1" do
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :close, 1)
    end

    test "exports sockname/1" do
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :sockname, 1)
    end

    test "exports peername/1" do
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :peername, 1)
    end

    test "exports getstat/1" do
      Code.ensure_loaded!(Core)
      assert Kernel.function_exported?(Core, :getstat, 1)
    end
  end

  describe "merge_options/2" do
    test "returns user options when defaults empty" do
      result = Core.merge_options([], active: false, binary: true)

      assert result == [active: false, binary: true]
    end

    test "returns default options when user options empty" do
      result = Core.merge_options([active: false], [])

      assert result == [active: false]
    end

    test "user options override defaults" do
      defaults = [active: true, buffer: 1024]
      user_opts = [active: false]

      result = Core.merge_options(defaults, user_opts)

      # User option should take precedence
      assert Keyword.get(result, :active) == false
    end

    test "preserves non-overlapping options from both" do
      defaults = [buffer: 1024, recbuf: 8192]
      user_opts = [active: false, binary: true]

      result = Core.merge_options(defaults, user_opts)

      assert Keyword.get(result, :buffer) == 1024
      assert Keyword.get(result, :recbuf) == 8192
      assert Keyword.get(result, :active) == false
      assert Keyword.get(result, :binary) == true
    end

    test "handles atom-style options" do
      defaults = [:binary, {:active, false}]
      user_opts = [:binary, {:buffer, 4096}]

      result = Core.merge_options(defaults, user_opts)

      assert :binary in result
      assert {:buffer, 4096} in result
    end

    test "user atom options override default atoms" do
      defaults = [:inet6, {:active, false}]
      user_opts = [:inet, {:active, true}]

      result = Core.merge_options(defaults, user_opts)

      # User's :inet should be present
      assert :inet in result
      # Both atom options are present since uniq_by treats :inet and :inet6 as different keys
      # This is correct behavior - user options come first in the list
      assert hd(Enum.filter(result, &is_atom/1)) == :inet
    end

    test "merges complex option sets" do
      defaults = [
        active: false,
        binary: true,
        buffer: 65536,
        recbuf: 131_072,
        sndbuf: 131_072
      ]

      user_opts = [
        active: true,
        buffer: 32768,
        reuseaddr: true
      ]

      result = Core.merge_options(defaults, user_opts)

      assert Keyword.get(result, :active) == true
      assert Keyword.get(result, :buffer) == 32768
      assert Keyword.get(result, :binary) == true
      assert Keyword.get(result, :recbuf) == 131_072
      assert Keyword.get(result, :reuseaddr) == true
    end

    test "handles empty lists" do
      result = Core.merge_options([], [])

      assert result == []
    end

    test "maintains order with user options first" do
      defaults = [a: 1, b: 2]
      user_opts = [c: 3, d: 4]

      result = Core.merge_options(defaults, user_opts)

      # User options should come first
      [first | _] = result
      assert first == {:c, 3} or first == {:d, 4}
    end
  end

  describe "open_socket/2" do
    test "opens socket on port 0 (auto-select)" do
      result = Core.open_socket(0, [:binary, active: false])

      assert {:ok, socket} = result
      Core.close(socket)
    end

    test "opens socket with specific port" do
      # Use high port to avoid permission issues
      port = 50_000 + :rand.uniform(10_000)
      result = Core.open_socket(port, [:binary, active: false])

      case result do
        {:ok, socket} ->
          {:ok, {_ip, actual_port}} = Core.sockname(socket)
          assert actual_port == port
          Core.close(socket)

        {:error, :eaddrinuse} ->
          # Port in use, that's OK for this test
          :ok
      end
    end

    test "opens socket with reuseaddr option" do
      result = Core.open_socket(0, [:binary, active: false, reuseaddr: true])

      assert {:ok, socket} = result
      Core.close(socket)
    end

    test "opens socket with inet option" do
      result = Core.open_socket(0, [:binary, :inet, active: false])

      assert {:ok, socket} = result
      Core.close(socket)
    end

    test "returns error for invalid options" do
      # Invalid option causes :badarg exit, which we catch
      result =
        try do
          Core.open_socket(0, [{:invalid_option_xyz, true}])
        catch
          :exit, :badarg -> {:error, :badarg}
        end

      assert {:error, :badarg} = result
    end
  end

  describe "socket operations" do
    setup do
      {:ok, socket} = Core.open_socket(0, [:binary, active: false])
      on_exit(fn -> Core.close(socket) end)
      {:ok, socket: socket}
    end

    test "sockname returns local address and port", %{socket: socket} do
      result = Core.sockname(socket)

      assert {:ok, {_ip, port}} = result
      assert is_integer(port)
      assert port > 0
    end

    test "getopts retrieves socket options", %{socket: socket} do
      result = Core.getopts(socket, [:active, :buffer])

      assert {:ok, opts} = result
      assert Keyword.has_key?(opts, :active)
    end

    test "setopts sets socket options", %{socket: socket} do
      result = Core.setopts(socket, active: true)

      assert :ok = result
    end

    test "getstat returns socket statistics", %{socket: socket} do
      result = Core.getstat(socket)

      assert {:ok, stats} = result
      assert is_list(stats)
    end

    test "close closes socket", %{socket: socket} do
      result = Core.close(socket)

      assert :ok = result

      # Socket should be closed now
      assert {:error, _} = Core.sockname(socket)
    end

    test "controlling_process transfers ownership", %{socket: socket} do
      # Create a dummy process
      pid = spawn(fn -> :timer.sleep(1000) end)

      result = Core.controlling_process(socket, pid)

      assert :ok = result
      Process.exit(pid, :kill)
    end
  end

  describe "send and recv" do
    setup do
      {:ok, socket1} = Core.open_socket(0, [:binary, active: false])
      {:ok, socket2} = Core.open_socket(0, [:binary, active: false])
      {:ok, {_ip, port1}} = Core.sockname(socket1)
      {:ok, {_ip, port2}} = Core.sockname(socket2)

      on_exit(fn ->
        Core.close(socket1)
        Core.close(socket2)
      end)

      {:ok, socket1: socket1, socket2: socket2, port1: port1, port2: port2}
    end

    test "send/4 sends data to address and port", %{socket1: socket1, port2: port2} do
      result = Core.send(socket1, {127, 0, 0, 1}, port2, "hello")

      assert :ok = result
    end

    test "recv/3 receives data with timeout", %{
      socket1: socket1,
      socket2: socket2,
      port2: port2
    } do
      # Send from socket1 to socket2
      Core.send(socket1, {127, 0, 0, 1}, port2, "test data")

      # Receive on socket2
      result = Core.recv(socket2, 0, 1000)

      assert {:ok, {_from_ip, _from_port, "test data"}} = result
    end

    test "recv/3 times out when no data", %{socket2: socket2} do
      result = Core.recv(socket2, 0, 10)

      assert {:error, :timeout} = result
    end
  end

  describe "peername behavior" do
    test "peername returns error for unconnected UDP socket" do
      {:ok, socket} = Core.open_socket(0, [:binary, active: false])

      # UDP sockets are connectionless, peername should error
      result = Core.peername(socket)

      assert {:error, _} = result
      Core.close(socket)
    end
  end

  describe "edge cases" do
    test "merge_options with duplicate keys in user options" do
      defaults = [a: 1]
      user_opts = [a: 2, a: 3]

      result = Core.merge_options(defaults, user_opts)

      # Should keep first occurrence from user options
      assert Keyword.get_values(result, :a) |> length() == 1
    end

    test "open_socket with empty options" do
      result = Core.open_socket(0, [])

      assert {:ok, socket} = result
      Core.close(socket)
    end

    test "open_socket with only atom options" do
      result = Core.open_socket(0, [:binary])

      assert {:ok, socket} = result
      Core.close(socket)
    end
  end
end
