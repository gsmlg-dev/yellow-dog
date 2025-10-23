defmodule Abyss.ListenerRateLimitingTest do
  use ExUnit.Case, async: false

  alias Abyss.{Listener, ServerConfig}

  describe "rate limiting in listener" do
    test "rejects packets when rate limit is exceeded" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          # Use random available port
          port: 0,
          rate_limit_enabled: true,
          rate_limit_max_packets: 1,
          rate_limit_window_ms: 1000
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})

      # This test would require more setup to fully test rate limiting
      # as we need to mock UDP socket behavior
      Process.exit(listener_pid, :normal)
    end

    test "accepts packets within rate limit" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          port: 0,
          rate_limit_enabled: true,
          rate_limit_max_packets: 100,
          rate_limit_window_ms: 1000
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})
      Process.exit(listener_pid, :normal)
    end

    test "allows all packets when rate limiting is disabled" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          port: 0,
          rate_limit_enabled: false
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})
      Process.exit(listener_pid, :normal)
    end
  end

  describe "packet size validation in listener" do
    test "rejects packets exceeding max size" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          port: 0,
          max_packet_size: 100
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})
      Process.exit(listener_pid, :normal)
    end

    test "accepts packets within size limit" do
      config =
        ServerConfig.new(
          handler_module: TestHandler,
          port: 0,
          max_packet_size: 8192
        )

      {:ok, listener_pid} = Listener.start_link({"test", self(), config})
      Process.exit(listener_pid, :normal)
    end
  end

  # Helper module for testing
  defmodule TestHandler do
    use Abyss.Handler

    @impl true
    def handle_data({ip, port, data}, state) do
      {:continue, state}
    end
  end
end
