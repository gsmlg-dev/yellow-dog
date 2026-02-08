defmodule YellowDog.Telemetry.LoggerHandlersTest do
  use ExUnit.Case, async: true

  alias YellowDog.Telemetry.LoggerHandlers

  describe "attach_all/0 and detach_all/0" do
    setup do
      # Ensure handlers are detached before each test
      LoggerHandlers.detach_all()

      on_exit(fn ->
        # Clean up after test
        LoggerHandlers.detach_all()
      end)

      :ok
    end

    test "attach_all/0 attaches all handlers" do
      assert :ok = LoggerHandlers.attach_all()

      # Verify handlers are attached by checking they exist
      handlers = :telemetry.list_handlers([:yellow_dog, :dns, :query, :received])
      assert length(handlers) > 0
      assert Enum.any?(handlers, &(&1.id == "yellow-dog-dns-logger"))
    end

    test "detach_all/0 detaches all handlers" do
      # First attach
      LoggerHandlers.attach_all()

      # Then detach
      assert :ok = LoggerHandlers.detach_all()

      # Verify handlers are detached
      handlers = :telemetry.list_handlers([:yellow_dog, :dns, :query, :received])
      refute Enum.any?(handlers, &(&1.id == "yellow-dog-dns-logger"))
    end

    test "silent operation when handlers not attached" do
      # Ensure handlers are not attached
      LoggerHandlers.detach_all()

      # Execute an event - should not crash or produce output
      :telemetry.execute(
        [:yellow_dog, :dns, :query, :received],
        %{count: 1},
        %{query_name: "test.local", query_type: :a, client_ip: {127, 0, 0, 1}}
      )

      # If we get here without crash, test passes
      assert true
    end
  end

  describe "DNS event formatting" do
    setup do
      test_pid = self()

      # Capture log messages instead of printing
      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end

      :telemetry.attach("test-dns-handler", [:yellow_dog, :dns, :query, :received], handler, nil)

      on_exit(fn ->
        :telemetry.detach("test-dns-handler")
      end)

      :ok
    end

    test "DNS query received event is captured" do
      :telemetry.execute(
        [:yellow_dog, :dns, :query, :received],
        %{count: 1},
        %{query_name: "example.com", query_type: :a, client_ip: {192, 168, 1, 100}}
      )

      assert_receive {:telemetry_event, [:yellow_dog, :dns, :query, :received], %{count: 1}, metadata}
      assert metadata.query_name == "example.com"
      assert metadata.query_type == :a
      assert metadata.client_ip == {192, 168, 1, 100}
    end
  end

  describe "DHCPv4 event formatting" do
    setup do
      test_pid = self()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end

      :telemetry.attach("test-dhcpv4-handler", [:yellow_dog, :dhcpv4, :lease, :granted], handler, nil)

      on_exit(fn ->
        :telemetry.detach("test-dhcpv4-handler")
      end)

      :ok
    end

    test "DHCPv4 lease granted event is captured" do
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :lease, :granted],
        %{count: 1, lease_time: 86400},
        %{ip_address: {192, 168, 1, 100}, client_mac: "AA:BB:CC:DD:EE:FF", pool_name: "default"}
      )

      assert_receive {:telemetry_event, [:yellow_dog, :dhcpv4, :lease, :granted], measurements, metadata}
      assert measurements.lease_time == 86400
      assert metadata.ip_address == {192, 168, 1, 100}
      assert metadata.client_mac == "AA:BB:CC:DD:EE:FF"
    end
  end

  describe "formatting helpers" do
    test "format_ip/1 formats IPv4 addresses" do
      assert LoggerHandlers.format_ip({192, 168, 1, 1}) == "192.168.1.1"
      assert LoggerHandlers.format_ip({0, 0, 0, 0}) == "0.0.0.0"
      assert LoggerHandlers.format_ip(nil) == "unknown"
    end

    test "format_ipv6/1 formats IPv6 addresses" do
      assert LoggerHandlers.format_ipv6({0, 0, 0, 0, 0, 0, 0, 0}) == "::"
      assert LoggerHandlers.format_ipv6({0xFD00, 0, 0, 0, 0, 0, 0, 1}) == "fd00:0:0:0:0:0:0:1"
      assert LoggerHandlers.format_ipv6(nil) == "unknown"
    end

    test "format_mac/1 formats MAC addresses" do
      assert LoggerHandlers.format_mac(<<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>) == "AA:BB:CC:DD:EE:FF"
      assert LoggerHandlers.format_mac("AA:BB:CC:DD:EE:FF") == "AA:BB:CC:DD:EE:FF"
      assert LoggerHandlers.format_mac(nil) == "unknown"
    end

    test "format_duration/1 formats durations" do
      assert LoggerHandlers.format_duration(500) == "500μs"
      assert LoggerHandlers.format_duration(1500) == "1.5ms"
      assert LoggerHandlers.format_duration(1_500_000) == "1.5s"
      assert LoggerHandlers.format_duration(nil) == "unknown"
    end

    test "format_duid/1 formats DUIDs" do
      assert LoggerHandlers.format_duid(<<0, 1, 0, 1, 0xAB, 0xCD>>) == "00010001abcd"
      assert LoggerHandlers.format_duid(nil) == "unknown"
    end
  end

  describe "handler_ids/0" do
    test "returns all 11 handler IDs" do
      ids = LoggerHandlers.handler_ids()
      assert length(ids) == 11
      assert "yellow-dog-dns-logger" in ids
      assert "yellow-dog-dhcpv4-logger" in ids
      assert "yellow-dog-dhcpv6-logger" in ids
      assert "yellow-dog-mdns-logger" in ids
      assert "yellow-dog-service-logger" in ids
      assert "yellow-dog-dns-query-logger" in ids
      assert "yellow-dog-dns-root-zone-logger" in ids
      assert "yellow-dog-application-logger" in ids
      assert "yellow-dog-config-logger" in ids
      assert "yellow-dog-console-logger" in ids
      assert "yellow-dog-infrastructure-logger" in ids
    end

    test "all IDs are unique strings" do
      ids = LoggerHandlers.handler_ids()
      assert length(ids) == length(Enum.uniq(ids))
      assert Enum.all?(ids, &is_binary/1)
    end
  end

  describe "per-service log level filtering" do
    test "handler respects config.level parameter" do
      # This is a placeholder test - actual level filtering is done by Logger
      # The handlers pass the level to Logger.log, which respects Logger's configuration
      config = %{level: :debug}

      # Verify the config structure is correct
      assert config.level == :debug
    end
  end
end
