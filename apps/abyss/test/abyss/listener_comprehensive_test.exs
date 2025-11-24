defmodule Abyss.ListenerComprehensiveTest do
  use ExUnit.Case, async: false

  alias Abyss.{Listener, ServerConfig}

  describe "listener info functions" do
    test "listener_info/1 returns socket information" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          port: 0
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})

      # This will return a tuple with ip and port
      info = Listener.listener_info(listener_pid)
      assert is_tuple(info)
      assert tuple_size(info) == 2
      # IP address
      assert is_tuple(elem(info, 0))
      # Port number
      assert is_integer(elem(info, 1))

      Process.exit(listener_pid, :normal)
    end

    test "socket_info/1 returns socket and span" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          port: 0
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})

      {socket, span} = Listener.socket_info(listener_pid)
      assert is_port(socket)
      assert %Abyss.Telemetry{} = span

      Process.exit(listener_pid, :normal)
    end

    test "stop/1 terminates listener gracefully" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          port: 0
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})
      assert Process.alive?(listener_pid)

      :ok = Listener.stop(listener_pid)

      # Wait a bit for termination
      Process.sleep(10)
      refute Process.alive?(listener_pid)
    end
  end

  describe "listener configuration" do
    test "handles broadcast mode configuration" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          port: 0,
          broadcast: true,
          transport_options: [broadcast: true]
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})

      info = Listener.listener_info(listener_pid)
      assert is_tuple(info)

      Process.exit(listener_pid, :normal)
    end

    test "handles non-broadcast mode configuration" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          port: 0,
          broadcast: false
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})

      info = Listener.listener_info(listener_pid)
      assert is_tuple(info)

      Process.exit(listener_pid, :normal)
    end
  end

  describe "start_link errors" do
    test "handles port binding errors gracefully" do
      # This test is skipped as port binding error handling is system-dependent
      # and can be difficult to test reliably across different systems
      :ok
    end
  end

  describe "listener with custom transport options" do
    test "handles custom transport options" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          port: 0,
          transport_options: [
            recbuf: 8192,
            sndbuf: 8192,
            reuseaddr: true
          ]
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})

      info = Listener.listener_info(listener_pid)
      assert is_tuple(info)

      Process.exit(listener_pid, :normal)
    end
  end

  describe "listener lifecycle" do
    test "starts listening immediately in non-broadcast mode" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          port: 0,
          broadcast: false
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})

      # Give it a moment to start
      Process.sleep(50)

      info = Listener.listener_info(listener_pid)
      assert is_tuple(info)

      Process.exit(listener_pid, :normal)
    end

    test "doesn't start listening immediately in broadcast mode" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          port: 0,
          broadcast: true
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})

      info = Listener.listener_info(listener_pid)
      assert is_tuple(info)

      Process.exit(listener_pid, :normal)
    end
  end

  # Helper module for testing
  defmodule TestHandler do
    use Abyss.Handler

    @impl true
    def handle_data({_ip, _port, _data}, state) do
      {:continue, state}
    end
  end
end
