defmodule YellowDog.Console.Settings.AddressPoolTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Console.Settings.AddressPool.

  Tests cover:
  - Ecto schema structure
  - Changeset validation for required fields
  - IPv4 address validation
  - IPv6 address validation
  - Range validation
  - Lifetime validation (DHCPv6)
  - DNS server validation
  - Protocol-specific field requirements
  """
  use ExUnit.Case, async: true

  alias YellowDog.Console.Settings.AddressPool

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(AddressPool)
    end

    test "exports changeset/2" do
      Code.ensure_loaded!(AddressPool)
      assert Kernel.function_exported?(AddressPool, :changeset, 2)
    end

    test "defines struct" do
      pool = %AddressPool{}
      assert is_map(pool)
    end

    test "struct has all expected fields" do
      pool = %AddressPool{}

      assert Map.has_key?(pool, :id)
      assert Map.has_key?(pool, :name)
      assert Map.has_key?(pool, :range_start)
      assert Map.has_key?(pool, :range_end)
      assert Map.has_key?(pool, :lease_time)
      assert Map.has_key?(pool, :preferred_lifetime)
      assert Map.has_key?(pool, :valid_lifetime)
      assert Map.has_key?(pool, :gateway)
      assert Map.has_key?(pool, :dns_servers)
      assert Map.has_key?(pool, :protocol)
    end

    test "dns_servers defaults to empty list" do
      pool = %AddressPool{}
      assert pool.dns_servers == []
    end
  end

  describe "changeset/2 - required fields" do
    test "requires name" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv4,
          lease_time: 3600
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :name)
    end

    test "requires range_start" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_end: "192.168.1.200",
          protocol: :ipv4,
          lease_time: 3600
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :range_start)
    end

    test "requires range_end" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          protocol: :ipv4,
          lease_time: 3600
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :range_end)
    end

    test "requires protocol" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          lease_time: 3600
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :protocol)
    end
  end

  describe "changeset/2 - IPv4 pools" do
    test "valid IPv4 pool changeset" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv4,
          lease_time: 3600
        })

      assert changeset.valid?
    end

    test "requires lease_time for IPv4" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv4
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :lease_time)
    end

    test "lease_time must be greater than 60 seconds" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv4,
          lease_time: 60
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :lease_time)
    end

    test "accepts optional gateway" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv4,
          lease_time: 3600,
          gateway: "192.168.1.1"
        })

      assert changeset.valid?
    end

    test "validates gateway is valid IPv4" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv4,
          lease_time: 3600,
          gateway: "not-an-ip"
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :gateway)
    end

    test "rejects IPv6 address for IPv4 pool" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "2001:db8::1",
          range_end: "2001:db8::100",
          protocol: :ipv4,
          lease_time: 3600
        })

      refute changeset.valid?
    end
  end

  describe "changeset/2 - IPv6 pools" do
    test "valid IPv6 pool changeset" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "2001:db8::1",
          range_end: "2001:db8::100",
          protocol: :ipv6,
          preferred_lifetime: 3600,
          valid_lifetime: 7200
        })

      assert changeset.valid?
    end

    test "requires preferred_lifetime for IPv6" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "2001:db8::1",
          range_end: "2001:db8::100",
          protocol: :ipv6,
          valid_lifetime: 7200
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :preferred_lifetime)
    end

    test "requires valid_lifetime for IPv6" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "2001:db8::1",
          range_end: "2001:db8::100",
          protocol: :ipv6,
          preferred_lifetime: 3600
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :valid_lifetime)
    end

    test "preferred_lifetime must be greater than 60" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "2001:db8::1",
          range_end: "2001:db8::100",
          protocol: :ipv6,
          preferred_lifetime: 60,
          valid_lifetime: 7200
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :preferred_lifetime)
    end

    test "valid_lifetime must be greater than 60" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "2001:db8::1",
          range_end: "2001:db8::100",
          protocol: :ipv6,
          preferred_lifetime: 3600,
          valid_lifetime: 60
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :valid_lifetime)
    end

    test "preferred_lifetime must be less than or equal to valid_lifetime" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "2001:db8::1",
          range_end: "2001:db8::100",
          protocol: :ipv6,
          preferred_lifetime: 7200,
          valid_lifetime: 3600
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :preferred_lifetime)
    end

    test "accepts equal preferred and valid lifetimes" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "2001:db8::1",
          range_end: "2001:db8::100",
          protocol: :ipv6,
          preferred_lifetime: 3600,
          valid_lifetime: 3600
        })

      assert changeset.valid?
    end

    test "rejects IPv4 address for IPv6 pool" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv6,
          preferred_lifetime: 3600,
          valid_lifetime: 7200
        })

      refute changeset.valid?
    end
  end

  describe "changeset/2 - DNS servers validation" do
    test "accepts valid IPv4 DNS servers" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv4,
          lease_time: 3600,
          dns_servers: ["8.8.8.8", "8.8.4.4"]
        })

      assert changeset.valid?
    end

    test "accepts valid IPv6 DNS servers" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "2001:db8::1",
          range_end: "2001:db8::100",
          protocol: :ipv6,
          preferred_lifetime: 3600,
          valid_lifetime: 7200,
          dns_servers: ["2001:4860:4860::8888", "2001:4860:4860::8844"]
        })

      assert changeset.valid?
    end

    test "rejects invalid DNS servers" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv4,
          lease_time: 3600,
          dns_servers: ["not-an-ip"]
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :dns_servers)
    end

    test "rejects IPv6 DNS server in IPv4 pool" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv4,
          lease_time: 3600,
          dns_servers: ["2001:4860:4860::8888"]
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :dns_servers)
    end

    test "rejects IPv4 DNS server in IPv6 pool" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "2001:db8::1",
          range_end: "2001:db8::100",
          protocol: :ipv6,
          preferred_lifetime: 3600,
          valid_lifetime: 7200,
          dns_servers: ["8.8.8.8"]
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :dns_servers)
    end

    test "accepts empty DNS servers list" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv4,
          lease_time: 3600,
          dns_servers: []
        })

      assert changeset.valid?
    end
  end

  describe "changeset/2 - ID field" do
    test "accepts custom ID" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          id: "custom-uuid-123",
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv4,
          lease_time: 3600
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :id) == "custom-uuid-123"
    end
  end

  describe "changeset/2 - range validation" do
    test "range_start must be less than range_end for IPv4" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.200",
          range_end: "192.168.1.100",
          protocol: :ipv4,
          lease_time: 3600
        })

      refute changeset.valid?
    end

    test "range_start must be less than range_end for IPv6" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "2001:db8::100",
          range_end: "2001:db8::1",
          protocol: :ipv6,
          preferred_lifetime: 3600,
          valid_lifetime: 7200
        })

      refute changeset.valid?
    end
  end

  describe "changeset/2 - protocol validation" do
    test "rejects invalid protocol" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :invalid,
          lease_time: 3600
        })

      refute changeset.valid?
    end

    test "accepts :ipv4 protocol" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          protocol: :ipv4,
          lease_time: 3600
        })

      assert changeset.valid?
    end

    test "accepts :ipv6 protocol" do
      changeset =
        AddressPool.changeset(%AddressPool{}, %{
          name: "test_pool",
          range_start: "2001:db8::1",
          range_end: "2001:db8::100",
          protocol: :ipv6,
          preferred_lifetime: 3600,
          valid_lifetime: 7200
        })

      assert changeset.valid?
    end
  end
end
