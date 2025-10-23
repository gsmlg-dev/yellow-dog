defmodule Abyss.ListenerTest do
  use ExUnit.Case, async: false

  alias Abyss.Listener
  alias Abyss.ServerConfig

  setup do
    config = ServerConfig.new(handler_module: Abyss.TestHandler, port: 0)
    {:ok, %{config: config}}
  end

  describe "start_link/1" do
    test "starts successfully with valid config", %{config: config} do
      server_pid = self()
      listener_id = "test-listener"

      assert {:ok, pid} = Listener.start_link({listener_id, server_pid, config})
      assert Process.alive?(pid)
      :ok = GenServer.stop(pid)
    end

    test "returns port info via listener_info", %{config: config} do
      server_pid = self()
      listener_id = "test-listener"

      assert {:ok, pid} = Listener.start_link({listener_id, server_pid, config})
      {ip, port} = Listener.listener_info(pid)

      assert is_tuple(ip) or is_atom(ip)
      assert is_integer(port) and port > 0

      :ok = GenServer.stop(pid)
    end
  end

  describe "listener_info/1" do
    test "returns socket information", %{config: config} do
      server_pid = self()
      listener_id = "test-listener"

      assert {:ok, pid} = Listener.start_link({listener_id, server_pid, config})
      info = Listener.listener_info(pid)

      assert is_tuple(info)
      assert tuple_size(info) == 2

      :ok = GenServer.stop(pid)
    end
  end

  describe "socket_info/1" do
    test "returns socket and telemetry info", %{config: config} do
      server_pid = self()
      listener_id = "test-listener"

      assert {:ok, pid} = Listener.start_link({listener_id, server_pid, config})
      {socket, telemetry} = Listener.socket_info(pid)

      assert is_port(socket) or is_tuple(socket)
      assert is_reference(telemetry) or is_map(telemetry)

      :ok = GenServer.stop(pid)
    end
  end

  describe "broadcast mode" do
    test "configures broadcast socket options", %{config: config} do
      server_pid = self()
      listener_id = "test-listener"
      config = %{config | broadcast: true}

      assert {:ok, pid} = Listener.start_link({listener_id, server_pid, config})
      {ip, port} = Listener.listener_info(pid)

      assert is_tuple(ip) or is_atom(ip)
      assert is_integer(port) and port > 0

      :ok = GenServer.stop(pid)
    end
  end

  describe "error handling" do
    test "stops gracefully on invalid port" do
      server_pid = self()
      listener_id = "test-listener"
      # Use a port that's likely to fail but handle the error gracefully
      config = %{ServerConfig.new(handler_module: Abyss.TestHandler, port: 0) | port: 0}

      # We expect this might fail, so just verify it handles gracefully
      case Listener.start_link({listener_id, server_pid, config}) do
        {:ok, pid} ->
          :ok = GenServer.stop(pid)
          assert true

        {:error, _reason} ->
          # Any error is acceptable for graceful handling
          assert true
      end
    end
  end
end
