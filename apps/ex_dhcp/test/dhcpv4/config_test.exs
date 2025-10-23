defmodule DHCPv4.ConfigTest do
  use ExUnit.Case
  alias DHCPv4.Config

  describe "new/1" do
    test "creates valid configuration" do
      assert {:ok, config} =
               Config.new(
                 subnet: {192, 168, 1, 0},
                 netmask: {255, 255, 255, 0},
                 range_start: {192, 168, 1, 100},
                 range_end: {192, 168, 1, 200},
                 gateway: {192, 168, 1, 1},
                 dns_servers: [{8, 8, 8, 8}],
                 lease_time: 3600
               )

      assert config.subnet == {192, 168, 1, 0}
      assert config.range_start == {192, 168, 1, 100}
      assert config.lease_time == 3600
    end

    test "validates subnet" do
      assert {:error, "Invalid subnet address"} =
               Config.new(
                 subnet: {256, 168, 1, 0},
                 netmask: {255, 255, 255, 0},
                 range_start: {192, 168, 1, 100},
                 range_end: {192, 168, 1, 200}
               )
    end

    test "validates range within subnet" do
      assert {:error, "range_start not in subnet"} =
               Config.new(
                 subnet: {192, 168, 1, 0},
                 netmask: {255, 255, 255, 0},
                 range_start: {10, 0, 0, 100},
                 range_end: {192, 168, 1, 200}
               )
    end

    test "validates range order" do
      assert {:error, "range_start must be before range_end"} =
               Config.new(
                 subnet: {192, 168, 1, 0},
                 netmask: {255, 255, 255, 0},
                 range_start: {192, 168, 1, 200},
                 range_end: {192, 168, 1, 100}
               )
    end

    test "validates lease time" do
      assert {:error, "lease_time must be at least 60 seconds"} =
               Config.new(
                 subnet: {192, 168, 1, 0},
                 netmask: {255, 255, 255, 0},
                 range_start: {192, 168, 1, 100},
                 range_end: {192, 168, 1, 200},
                 lease_time: 30
               )
    end
  end

  describe "new!/1" do
    test "creates configuration or raises" do
      config =
        Config.new!(
          subnet: {192, 168, 1, 0},
          netmask: {255, 255, 255, 0},
          range_start: {192, 168, 1, 100},
          range_end: {192, 168, 1, 200}
        )

      assert config.subnet == {192, 168, 1, 0}

      assert_raise ArgumentError, fn ->
        Config.new!(subnet: {256, 168, 1, 0})
      end
    end
  end
end
