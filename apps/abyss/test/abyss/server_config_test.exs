defmodule Abyss.ServerConfigTest do
  use ExUnit.Case, async: true
  doctest Abyss.ServerConfig

  describe "new/1" do
    test "creates config with default values" do
      config = Abyss.ServerConfig.new(handler_module: Abyss.TestHandler, port: 1234)

      assert config.handler_module == Abyss.TestHandler
      assert config.port == 1234
      assert config.handler_options == []
      assert config.genserver_options == []
      assert config.supervisor_options == []
      assert config.transport_options == []
      assert config.num_listeners == 100
      assert config.num_connections == 16_384
      assert config.max_connections_retry_count == 5
      assert config.max_connections_retry_wait == 1000
      assert config.read_timeout == 60_000
      assert config.shutdown_timeout == 15_000
      assert config.silent_terminate_on_error == false
      assert config.broadcast == false
      assert config.udp_buffer_size == 64 * 1024
      assert config.dynamic_listeners == false
      assert config.min_listeners == 10
      assert config.max_listeners == 1000
      assert config.listener_scale_threshold == 0.8
    end

    test "allows custom configuration values" do
      config =
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 5678,
          transport_options: [recbuf: 8192],
          num_listeners: 10,
          num_connections: 1000,
          read_timeout: 30_000,
          broadcast: true
        )

      assert config.handler_module == Abyss.TestHandler
      assert config.port == 5678
      assert config.transport_options == [recbuf: 8192]
      assert config.num_listeners == 10
      assert config.num_connections == 1000
      assert config.read_timeout == 30_000
      assert config.broadcast == true
    end

    test "accepts any handler module (no validation)" do
      config = Abyss.ServerConfig.new(handler_module: :not_a_module, port: 1234)
      assert config.handler_module == :not_a_module
    end

    test "accepts any port value" do
      config = Abyss.ServerConfig.new(handler_module: Abyss.TestHandler, port: -1)
      assert config.port == -1

      config = Abyss.ServerConfig.new(handler_module: Abyss.TestHandler, port: 99999)
      assert config.port == 99999
    end

    test "accepts any num_listeners value" do
      config =
        Abyss.ServerConfig.new(handler_module: Abyss.TestHandler, port: 1234, num_listeners: 0)

      assert config.num_listeners == 0

      config =
        Abyss.ServerConfig.new(handler_module: Abyss.TestHandler, port: 1234, num_listeners: -5)

      assert config.num_listeners == -5
    end

    test "accepts any num_connections value" do
      config =
        Abyss.ServerConfig.new(handler_module: Abyss.TestHandler, port: 1234, num_connections: -1)

      assert config.num_connections == -1

      config =
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          num_connections: :infinity
        )

      assert config.num_connections == :infinity
    end

    test "accepts any timeout values" do
      config =
        Abyss.ServerConfig.new(handler_module: Abyss.TestHandler, port: 1234, read_timeout: -1)

      assert config.read_timeout == -1

      config =
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          shutdown_timeout: -1000
        )

      assert config.shutdown_timeout == -1000
    end

    test "accepts UDP buffer size configuration" do
      config =
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          udp_buffer_size: 128 * 1024
        )

      assert config.udp_buffer_size == 128 * 1024
    end

    test "accepts dynamic listener configuration" do
      config =
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          dynamic_listeners: true,
          min_listeners: 5,
          max_listeners: 500,
          listener_scale_threshold: 0.7
        )

      assert config.dynamic_listeners == true
      assert config.min_listeners == 5
      assert config.max_listeners == 500
      assert config.listener_scale_threshold == 0.7
    end
  end

  describe "calculate_optimal_listeners/2" do
    test "calculates optimal listeners based on connection count" do
      # New algorithm: connections / 100 (1 listener per 100 connections)
      assert Abyss.ServerConfig.calculate_optimal_listeners(0, 100.0) == 1
      # base=5, factor=1, result=5
      assert Abyss.ServerConfig.calculate_optimal_listeners(500, 100.0) == 5
      # base=10, factor=1, result=10
      assert Abyss.ServerConfig.calculate_optimal_listeners(1000, 100.0) == 10
      # base=20, factor=1, result=20
      assert Abyss.ServerConfig.calculate_optimal_listeners(2000, 100.0) == 20
      # base=50, factor=1, result=50
      assert Abyss.ServerConfig.calculate_optimal_listeners(5000, 100.0) == 50
      # base=100, factor=1, result=100
      assert Abyss.ServerConfig.calculate_optimal_listeners(10000, 100.0) == 100
    end

    test "adjusts for processing time" do
      # Faster processing should require fewer listeners
      # base=20, factor=max(50.0/100, 0.5)=0.5, 20*0.5=10
      assert Abyss.ServerConfig.calculate_optimal_listeners(2000, 50.0) == 10
      # base=20, factor=max(25.0/100, 0.5)=0.5, 20*0.5=10
      assert Abyss.ServerConfig.calculate_optimal_listeners(2000, 25.0) == 10

      # Slower processing should require more listeners
      # base=10, factor=2, 10*2=20
      assert Abyss.ServerConfig.calculate_optimal_listeners(1000, 200.0) == 20
      # base=10, factor=5, 10*5=50
      assert Abyss.ServerConfig.calculate_optimal_listeners(1000, 500.0) == 50
      # base=10, factor=10, 10*10=100
      assert Abyss.ServerConfig.calculate_optimal_listeners(1000, 1000.0) == 100
    end

    test "always returns at least 1 listener" do
      assert Abyss.ServerConfig.calculate_optimal_listeners(0, 100.0) == 1
      # 0.1 -> 1
      assert Abyss.ServerConfig.calculate_optimal_listeners(100, 10.0) == 1
      # 0.001 -> 1
      assert Abyss.ServerConfig.calculate_optimal_listeners(1, 1.0) == 1
    end

    test "handles edge cases" do
      # Very fast processing time
      # base=10, factor=max(0.1/100, 0.5)=0.5, 10*0.5=5
      assert Abyss.ServerConfig.calculate_optimal_listeners(1000, 0.1) == 5

      # Very high processing time
      # base=1, factor=max(10000/100, 0.5)=100, 1*100=100
      assert Abyss.ServerConfig.calculate_optimal_listeners(100, 10000.0) == 100

      # Large connection count
      result = Abyss.ServerConfig.calculate_optimal_listeners(100_000, 100.0)
      # base=1000, factor=1, 1000*1=1000
      assert result == 1000

      # Combined high connections and slow processing
      result = Abyss.ServerConfig.calculate_optimal_listeners(10000, 500.0)
      # base=100, factor=5, 100*5=500
      assert result == 500
    end

    test "handles floating point processing times" do
      # base=10, factor=1.2345, 10 * 1.2345 = 12.345 -> round(12.345) = 12
      assert Abyss.ServerConfig.calculate_optimal_listeners(1000, 123.45) == 12
      # base=25, factor=0.873, 25 * 0.873 = 21.825 -> round(21.825) = 22
      assert Abyss.ServerConfig.calculate_optimal_listeners(2500, 87.3) == 22
      # base=15, factor=2.337, 15 * 2.337 = 35.055 -> round(35.055) = 35
      assert Abyss.ServerConfig.calculate_optimal_listeners(1500, 233.7) == 35
    end

    test "verifies processing factor calculation" do
      # Test the processing factor: max(avg_processing_time / 100, 0.5)

      # Below 100ms baseline
      # base=20, factor = max(0.5, 0.5) = 0.5, 20*0.5 = 10 -> round(10) = 10
      assert Abyss.ServerConfig.calculate_optimal_listeners(2000, 50.0) == 10
      # base=20, factor = max(0.999, 0.5) = 0.999, 20*0.999 = 19.98 -> round(19.98) = 20
      assert Abyss.ServerConfig.calculate_optimal_listeners(2000, 99.9) == 20

      # At 100ms baseline
      # base=20, factor = max(1, 0.5) = 1, 20*1 = 20 -> round(20) = 20
      assert Abyss.ServerConfig.calculate_optimal_listeners(2000, 100.0) == 20

      # Above 100ms baseline
      # base=20, factor = max(1.5, 0.5) = 1.5, 20*1.5 = 30 -> round(30) = 30
      assert Abyss.ServerConfig.calculate_optimal_listeners(2000, 150.0) == 30
      # base=20, factor = max(2, 0.5) = 2, 20*2 = 40 -> round(40) = 40
      assert Abyss.ServerConfig.calculate_optimal_listeners(2000, 200.0) == 40
    end
  end

  describe "new configuration options" do
    test "udp_buffer_size default and custom values" do
      default_config = Abyss.ServerConfig.new(handler_module: Abyss.TestHandler, port: 1234)
      assert default_config.udp_buffer_size == 64 * 1024

      custom_config =
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          udp_buffer_size: 32 * 1024
        )

      assert custom_config.udp_buffer_size == 32 * 1024
    end

    test "dynamic listener configuration defaults" do
      config = Abyss.ServerConfig.new(handler_module: Abyss.TestHandler, port: 1234)

      assert config.dynamic_listeners == false
      assert config.min_listeners == 10
      assert config.max_listeners == 1000
      assert config.listener_scale_threshold == 0.8
    end

    test "custom dynamic listener configuration" do
      config =
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          dynamic_listeners: true,
          min_listeners: 20,
          max_listeners: 200,
          listener_scale_threshold: 0.75
        )

      assert config.dynamic_listeners == true
      assert config.min_listeners == 20
      assert config.max_listeners == 200
      assert config.listener_scale_threshold == 0.75
    end

    test "invalid configuration values are rejected" do
      # Test min_listeners validation
      assert_raise ArgumentError, ~r/min_listeners must be positive/, fn ->
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          min_listeners: 0
        )
      end

      # Test min/max listeners relationship
      assert_raise ArgumentError, ~r/min_listeners must be positive and <= max_listeners/, fn ->
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          min_listeners: 100,
          max_listeners: 50
        )
      end

      # Test listener_scale_threshold bounds
      assert_raise ArgumentError, ~r/listener_scale_threshold must be between 0.0 and 1.0/, fn ->
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          listener_scale_threshold: 2.0
        )
      end

      # Test connection_telemetry_sample_rate bounds
      assert_raise ArgumentError, ~r/connection_telemetry_sample_rate must be between 0.0 and 1.0/, fn ->
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          connection_telemetry_sample_rate: 1.5
        )
      end

      # Test memory thresholds
      assert_raise ArgumentError, ~r/handler_memory_warning_threshold must be positive/, fn ->
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          handler_memory_warning_threshold: 200,
          handler_memory_hard_limit: 150
        )
      end
    end
  end

  describe "struct fields" do
    test "has correct struct definition" do
      config = Abyss.ServerConfig.new(handler_module: Abyss.TestHandler, port: 1234)

      assert %Abyss.ServerConfig{
               handler_module: Abyss.TestHandler,
               handler_options: [],
               genserver_options: [],
               supervisor_options: [],
               port: 1234,
               transport_options: [],
               broadcast: false,
               num_listeners: 100,
               num_connections: 16_384,
               max_connections_retry_count: 5,
               max_connections_retry_wait: 1000,
               read_timeout: 60_000,
               shutdown_timeout: 15_000,
               silent_terminate_on_error: false,
               rate_limit_enabled: false,
               rate_limit_max_packets: 1000,
               rate_limit_window_ms: 1000,
               max_packet_size: 8192
             } = config
    end
  end

  describe "rate limiting configuration" do
    test "includes rate limiting fields" do
      config =
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          rate_limit_enabled: true,
          rate_limit_max_packets: 500,
          rate_limit_window_ms: 2000
        )

      assert config.rate_limit_enabled == true
      assert config.rate_limit_max_packets == 500
      assert config.rate_limit_window_ms == 2000
    end

    test "has default rate limiting values" do
      config = Abyss.ServerConfig.new(handler_module: Abyss.TestHandler, port: 1234)

      assert config.rate_limit_enabled == false
      assert config.rate_limit_max_packets == 1000
      assert config.rate_limit_window_ms == 1000
    end
  end

  describe "packet size configuration" do
    test "includes max packet size field" do
      config =
        Abyss.ServerConfig.new(
          handler_module: Abyss.TestHandler,
          port: 1234,
          max_packet_size: 4096
        )

      assert config.max_packet_size == 4096
    end

    test "has default max packet size" do
      config = Abyss.ServerConfig.new(handler_module: Abyss.TestHandler, port: 1234)

      assert config.max_packet_size == 8192
    end
  end

  describe "validation" do
    test "raises error when handler_module is missing" do
      assert_raise ArgumentError, "No handler_module defined in server configuration", fn ->
        Abyss.ServerConfig.new(port: 1234)
      end
    end

    test "raises error when options is not a keyword list" do
      assert_raise ArgumentError, "configuration must be a keyword list", fn ->
        Abyss.ServerConfig.new([{"handler_module", Abyss.TestHandler}])
      end
    end

    test "raises error when handler_module is not an atom" do
      assert_raise ArgumentError, "handler_module must be a module", fn ->
        Abyss.ServerConfig.new(handler_module: "TestModule")
      end
    end
  end
end
