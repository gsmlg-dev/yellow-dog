defmodule YellowDog.Dhcpv4.LeaseTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv4.Lease

  @valid_mac <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
  @valid_ip {192, 168, 1, 100}

  describe "create/5" do
    test "creates a lease with required fields" do
      lease = Lease.create(@valid_ip, @valid_mac, "default", 3600)

      assert lease.ip == @valid_ip
      assert lease.mac == @valid_mac
      assert lease.pool_name == "default"
      assert lease.state == :active
      assert %DateTime{} = lease.starts_at
      assert %DateTime{} = lease.expires_at
    end

    test "accepts optional hostname" do
      lease = Lease.create(@valid_ip, @valid_mac, "pool1", 3600, hostname: "workstation")
      assert lease.hostname == "workstation"
    end

    test "accepts optional client_id" do
      lease = Lease.create(@valid_ip, @valid_mac, "pool1", 3600, client_id: <<1, 2, 3>>)
      assert lease.client_id == <<1, 2, 3>>
    end

    test "sets expires_at based on lease_time" do
      lease = Lease.create(@valid_ip, @valid_mac, "pool1", 7200)
      diff = DateTime.diff(lease.expires_at, lease.starts_at, :second)
      assert diff == 7200
    end
  end

  describe "new/1" do
    test "creates a lease from a config map with atom keys" do
      config = %{
        ip: "192.168.1.10",
        mac: @valid_mac,
        pool_name: "default",
        starts_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert {:ok, %Lease{ip: {192, 168, 1, 10}}} = Lease.new(config)
    end

    test "parses IP from string" do
      config = %{
        ip: "10.0.0.1",
        mac: @valid_mac,
        starts_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert {:ok, %Lease{ip: {10, 0, 0, 1}}} = Lease.new(config)
    end

    test "accepts IP tuple directly" do
      config = %{
        ip: {10, 0, 0, 1},
        mac: @valid_mac,
        starts_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert {:ok, %Lease{ip: {10, 0, 0, 1}}} = Lease.new(config)
    end

    test "returns error for missing IP" do
      config = %{mac: @valid_mac}
      assert {:error, "IP address is required"} = Lease.new(config)
    end

    test "returns error for missing MAC" do
      config = %{ip: "192.168.1.1"}
      assert {:error, "MAC address is required"} = Lease.new(config)
    end

    test "parses state from string" do
      config = %{
        ip: {10, 0, 0, 1},
        mac: @valid_mac,
        state: "offered",
        starts_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert {:ok, %Lease{state: :offered}} = Lease.new(config)
    end

    test "defaults state to :active" do
      config = %{
        ip: {10, 0, 0, 1},
        mac: @valid_mac,
        starts_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert {:ok, %Lease{state: :active}} = Lease.new(config)
    end
  end

  describe "expired?/1" do
    test "returns false for future expiration" do
      lease = Lease.create(@valid_ip, @valid_mac, "pool1", 3600)
      refute Lease.expired?(lease)
    end

    test "returns true for past expiration" do
      lease = %Lease{
        ip: @valid_ip,
        mac: @valid_mac,
        pool_name: "pool1",
        starts_at: DateTime.add(DateTime.utc_now(), -7200, :second),
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        state: :active
      }

      assert Lease.expired?(lease)
    end
  end

  describe "active?/1" do
    test "returns true for active non-expired lease" do
      lease = Lease.create(@valid_ip, @valid_mac, "pool1", 3600)
      assert Lease.active?(lease)
    end

    test "returns false for released lease" do
      lease = Lease.create(@valid_ip, @valid_mac, "pool1", 3600)
      released = Lease.release(lease)
      refute Lease.active?(released)
    end

    test "returns false for expired lease" do
      lease = %Lease{
        ip: @valid_ip,
        mac: @valid_mac,
        pool_name: "pool1",
        starts_at: DateTime.add(DateTime.utc_now(), -7200, :second),
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        state: :active
      }

      refute Lease.active?(lease)
    end
  end

  describe "release/1" do
    test "sets state to released" do
      lease = Lease.create(@valid_ip, @valid_mac, "pool1", 3600)
      released = Lease.release(lease)
      assert released.state == :released
    end

    test "preserves other fields" do
      lease = Lease.create(@valid_ip, @valid_mac, "pool1", 3600, hostname: "test")
      released = Lease.release(lease)
      assert released.ip == lease.ip
      assert released.hostname == "test"
    end
  end

  describe "decline/1" do
    test "sets state to declined" do
      lease = Lease.create(@valid_ip, @valid_mac, "pool1", 3600)
      declined = Lease.decline(lease)
      assert declined.state == :declined
    end
  end

  describe "renew/2" do
    test "updates expiration and sets state to active" do
      lease = Lease.create(@valid_ip, @valid_mac, "pool1", 100)
      renewed = Lease.renew(lease, 7200)

      assert renewed.state == :active
      assert DateTime.diff(renewed.expires_at, DateTime.utc_now(), :second) > 7100
    end
  end

  describe "validate/1" do
    test "validates a valid lease" do
      lease = Lease.create(@valid_ip, @valid_mac, "pool1", 3600)
      assert :ok = Lease.validate(lease)
    end

    test "returns error for invalid IP" do
      lease = %Lease{
        ip: {256, 0, 0, 1},
        mac: @valid_mac,
        pool_name: "pool1",
        starts_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert {:error, "Invalid IP address"} = Lease.validate(lease)
    end
  end

  describe "to_toml_map/1 and from_toml_map/1" do
    test "round-trips a lease through TOML serialization" do
      original = Lease.create(@valid_ip, @valid_mac, "pool1", 3600, hostname: "test-host")
      toml_map = Lease.to_toml_map(original)

      assert toml_map["ip"] == "192.168.1.100"
      assert toml_map["pool_name"] == "pool1"
      assert toml_map["hostname"] == "test-host"
      assert toml_map["state"] == "active"

      assert {:ok, restored} = Lease.from_toml_map(toml_map)
      assert restored.ip == original.ip
      assert restored.pool_name == original.pool_name
      assert restored.hostname == original.hostname
    end

    test "omits nil optional fields from TOML map" do
      lease = Lease.create(@valid_ip, @valid_mac, "pool1", 3600)
      toml_map = Lease.to_toml_map(lease)

      refute Map.has_key?(toml_map, "hostname")
      refute Map.has_key?(toml_map, "client_id")
    end
  end
end
