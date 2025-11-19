defmodule YellowDog.Console.ValidatorsTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.Validators

  describe "validate_ip/2" do
    test "validates valid IPv4 addresses" do
      assert :ok == Validators.validate_ip("192.168.1.1", :ipv4)
      assert :ok == Validators.validate_ip("0.0.0.0", :ipv4)
      assert :ok == Validators.validate_ip("255.255.255.255", :ipv4)
    end

    test "validates valid IPv6 addresses" do
      assert :ok == Validators.validate_ip("::1", :ipv6)
      assert :ok == Validators.validate_ip("2001:0db8:85a3:0000:0000:8a2e:0370:7334", :ipv6)
      assert :ok == Validators.validate_ip("::", :ipv6)
    end

    test "rejects invalid IPv4 addresses" do
      assert {:error, _} = Validators.validate_ip("256.1.1.1", :ipv4)
      assert {:error, _} = Validators.validate_ip("192.168.1", :ipv4)
      assert {:error, _} = Validators.validate_ip("invalid", :ipv4)
    end

    test "rejects IPv4 when expecting IPv6" do
      assert {:error, message} = Validators.validate_ip("192.168.1.1", :ipv6)
      assert message =~ "must be a valid IPv6 address"
    end

    test "rejects IPv6 when expecting IPv4" do
      assert {:error, message} = Validators.validate_ip("::1", :ipv4)
      assert message =~ "must be a valid IPv4 address"
    end
  end

  describe "validate_port/1" do
    test "validates valid ports" do
      assert :ok == Validators.validate_port(1)
      assert :ok == Validators.validate_port(53)
      assert :ok == Validators.validate_port(8080)
      assert :ok == Validators.validate_port(65535)
    end

    test "rejects invalid ports" do
      assert {:error, message} = Validators.validate_port(0)
      assert message =~ "between 1 and 65535"

      assert {:error, message} = Validators.validate_port(99999)
      assert message =~ "between 1 and 65535"

      assert {:error, message} = Validators.validate_port(-1)
      assert message =~ "between 1 and 65535"
    end
  end

  describe "validate_pool_range/3" do
    test "validates valid IPv4 range" do
      assert :ok == Validators.validate_pool_range("192.168.1.100", "192.168.1.200", :ipv4)
      assert :ok == Validators.validate_pool_range("10.0.0.1", "10.0.0.254", :ipv4)
    end

    test "validates valid IPv6 range" do
      assert :ok ==
               Validators.validate_pool_range(
                 "2001:db8::1",
                 "2001:db8::ffff",
                 :ipv6
               )
    end

    test "rejects range where start > end" do
      assert {:error, message} =
               Validators.validate_pool_range("192.168.1.200", "192.168.1.100", :ipv4)

      assert message =~ "start must be less than"
    end

    test "rejects invalid IP addresses in range" do
      assert {:error, _} = Validators.validate_pool_range("256.1.1.1", "192.168.1.200", :ipv4)
      assert {:error, _} = Validators.validate_pool_range("192.168.1.100", "invalid", :ipv4)
    end
  end

  describe "check_overlapping_pools/2" do
    test "accepts non-overlapping pools" do
      pools = [
        %{name: "Pool1", range_start: "192.168.1.100", range_end: "192.168.1.150"},
        %{name: "Pool2", range_start: "192.168.1.200", range_end: "192.168.1.250"}
      ]

      assert :ok == Validators.check_overlapping_pools(pools, :ipv4)
    end

    test "detects overlapping pools" do
      pools = [
        %{name: "Pool1", range_start: "192.168.1.100", range_end: "192.168.1.200"},
        %{name: "Pool2", range_start: "192.168.1.150", range_end: "192.168.1.250"}
      ]

      assert {:error, message} = Validators.check_overlapping_pools(pools, :ipv4)
      assert message =~ "Pool1"
      assert message =~ "Pool2"
      assert message =~ "overlaps"
    end

    test "handles adjacent pools (no overlap)" do
      pools = [
        %{name: "Pool1", range_start: "192.168.1.100", range_end: "192.168.1.199"},
        %{name: "Pool2", range_start: "192.168.1.200", range_end: "192.168.1.250"}
      ]

      assert :ok == Validators.check_overlapping_pools(pools, :ipv4)
    end

    test "handles single pool" do
      pools = [
        %{name: "Pool1", range_start: "192.168.1.100", range_end: "192.168.1.200"}
      ]

      assert :ok == Validators.check_overlapping_pools(pools, :ipv4)
    end

    test "handles empty pool list" do
      assert :ok == Validators.check_overlapping_pools([], :ipv4)
    end
  end
end
