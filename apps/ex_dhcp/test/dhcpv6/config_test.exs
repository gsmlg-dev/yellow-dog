defmodule DHCPv6.ConfigTest do
  use ExUnit.Case
  alias DHCPv6.Config

  describe "new/1" do
    test "creates valid IPv6 configuration" do
      assert {:ok, config} =
               Config.new(
                 prefix: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000},
                 prefix_length: 64,
                 range_start: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x1000},
                 range_end: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xFFFF},
                 dns_servers: [{0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}],
                 lease_time: 3600
               )

      assert config.prefix == {8193, 3512, 0, 0, 0, 0, 0, 0}
      assert config.prefix_length == 64
      assert config.lease_time == 3600
    end

    test "validates IPv6 prefix" do
      assert {:error, "Invalid IPv6 prefix"} =
               Config.new(
                 prefix: {0x2001, 0x0DB8, 0x10000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000},
                 prefix_length: 64,
                 range_start: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x1000},
                 range_end: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xFFFF}
               )
    end

    test "validates prefix length" do
      assert {:error, "Invalid prefix length (0-128)"} =
               Config.new(
                 prefix: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000},
                 prefix_length: 129,
                 range_start: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x1000},
                 range_end: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xFFFF}
               )
    end

    test "validates range within prefix" do
      assert {:error, _} =
               Config.new(
                 prefix: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000},
                 prefix_length: 64,
                 range_start: {0x2001, 0x1234, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x1000},
                 range_end: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xFFFF}
               )
    end

    test "validates range order" do
      assert {:error, "range_start must be before range_end"} =
               Config.new(
                 prefix: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000},
                 prefix_length: 64,
                 range_start: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xFFFF},
                 range_end: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x1000}
               )
    end

    test "validates DNS servers" do
      assert {:error, "Invalid DNS server address"} =
               Config.new(
                 prefix: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000},
                 prefix_length: 64,
                 range_start: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x1000},
                 range_end: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xFFFF},
                 dns_servers: [{0x2001, 0x0DB8, 0x10000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000}]
               )
    end

    test "validates lease time" do
      assert {:error, "lease_time must be at least 60 seconds"} =
               Config.new(
                 prefix: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000},
                 prefix_length: 64,
                 range_start: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x1000},
                 range_end: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xFFFF},
                 lease_time: 30
               )
    end
  end

  describe "new!/1" do
    test "creates configuration or raises" do
      config =
        Config.new!(
          prefix: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000},
          prefix_length: 64,
          range_start: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x1000},
          range_end: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xFFFF}
        )

      assert config.prefix_length == 64

      assert_raise ArgumentError, fn ->
        Config.new!(prefix: {0x2001, 0x0DB8, 0x10000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000})
      end
    end
  end
end
