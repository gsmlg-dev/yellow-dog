defmodule YellowDog.Dhcpv6.LeaseTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv6.Lease

  @valid_ip {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
  @valid_duid "00010001AABBCCDD"
  @valid_iaid 1001

  describe "create/6" do
    test "creates a lease with defaults" do
      lease =
        Lease.create(@valid_ip, @valid_duid, @valid_iaid, "pool1", %{preferred: 3600, valid: 7200})

      assert lease.ip == @valid_ip
      assert lease.duid == @valid_duid
      assert lease.iaid == @valid_iaid
      assert lease.pool_name == "pool1"
      assert lease.state == :active
      assert lease.hostname == nil
      assert %DateTime{} = lease.starts_at
      assert %DateTime{} = lease.preferred_until
      assert %DateTime{} = lease.valid_until
    end

    test "normalizes DUID by removing separators" do
      lease =
        Lease.create(@valid_ip, "00:01:00:01:AA:BB:CC:DD", @valid_iaid, "pool1", %{
          preferred: 3600,
          valid: 7200
        })

      assert lease.duid == @valid_duid
    end

    test "sets hostname from opts" do
      lease =
        Lease.create(
          @valid_ip,
          @valid_duid,
          @valid_iaid,
          "pool1",
          %{preferred: 3600, valid: 7200},
          hostname: "host1"
        )

      assert lease.hostname == "host1"
    end

    test "preferred_until is before valid_until" do
      lease =
        Lease.create(@valid_ip, @valid_duid, @valid_iaid, "pool1", %{preferred: 3600, valid: 7200})

      assert DateTime.before?(lease.preferred_until, lease.valid_until)
    end
  end

  describe "new/1" do
    test "creates a lease from a map with atom keys" do
      now = DateTime.utc_now()

      config = %{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        pool_name: "pool1",
        starts_at: now,
        preferred_until: DateTime.add(now, 3600, :second),
        valid_until: DateTime.add(now, 7200, :second),
        state: :active
      }

      assert {:ok, lease} = Lease.new(config)
      assert lease.ip == @valid_ip
      assert lease.pool_name == "pool1"
    end

    test "parses IPv6 address from string" do
      now = DateTime.utc_now()

      config = %{
        ip: "2001:db8::1",
        duid: @valid_duid,
        iaid: @valid_iaid,
        starts_at: now,
        preferred_until: DateTime.add(now, 3600, :second),
        valid_until: DateTime.add(now, 7200, :second)
      }

      assert {:ok, lease} = Lease.new(config)
      assert lease.ip == @valid_ip
    end

    test "parses IAID from string" do
      now = DateTime.utc_now()

      config = %{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: "1001",
        starts_at: now,
        preferred_until: DateTime.add(now, 3600, :second),
        valid_until: DateTime.add(now, 7200, :second)
      }

      assert {:ok, lease} = Lease.new(config)
      assert lease.iaid == 1001
    end

    test "parses datetimes from ISO 8601 strings" do
      config = %{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        starts_at: "2026-01-01T00:00:00Z",
        preferred_until: "2026-01-01T01:00:00Z",
        valid_until: "2026-01-01T02:00:00Z"
      }

      assert {:ok, lease} = Lease.new(config)
      assert lease.starts_at.year == 2026
    end

    test "parses datetimes from unix timestamps" do
      config = %{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        starts_at: 1_700_000_000,
        preferred_until: 1_700_003_600,
        valid_until: 1_700_007_200
      }

      assert {:ok, lease} = Lease.new(config)
      assert %DateTime{} = lease.starts_at
    end

    test "returns error for missing IP" do
      assert {:error, _} = Lease.new(%{duid: @valid_duid, iaid: @valid_iaid})
    end

    test "returns error for missing DUID" do
      assert {:error, _} = Lease.new(%{ip: @valid_ip, iaid: @valid_iaid})
    end

    test "returns error for missing IAID" do
      assert {:error, _} = Lease.new(%{ip: @valid_ip, duid: @valid_duid})
    end

    test "returns error for invalid IPv6 string" do
      assert {:error, _} = Lease.new(%{ip: "not-an-ip", duid: @valid_duid, iaid: @valid_iaid})
    end

    test "defaults pool_name to 'default'" do
      now = DateTime.utc_now()

      config = %{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        starts_at: now,
        preferred_until: DateTime.add(now, 3600, :second),
        valid_until: DateTime.add(now, 7200, :second)
      }

      assert {:ok, lease} = Lease.new(config)
      assert lease.pool_name == "default"
    end

    test "parses state from string" do
      now = DateTime.utc_now()

      config = %{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        starts_at: now,
        preferred_until: DateTime.add(now, 3600, :second),
        valid_until: DateTime.add(now, 7200, :second),
        state: "declined"
      }

      assert {:ok, lease} = Lease.new(config)
      assert lease.state == :declined
    end
  end

  describe "expired?/1" do
    test "returns true for expired lease" do
      lease = %Lease{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        pool_name: "pool1",
        starts_at: DateTime.add(DateTime.utc_now(), -7200, :second),
        preferred_until: DateTime.add(DateTime.utc_now(), -3600, :second),
        valid_until: DateTime.add(DateTime.utc_now(), -1, :second),
        state: :active
      }

      assert Lease.expired?(lease)
    end

    test "returns false for non-expired lease" do
      lease = %Lease{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        pool_name: "pool1",
        starts_at: DateTime.utc_now(),
        preferred_until: DateTime.add(DateTime.utc_now(), 3600, :second),
        valid_until: DateTime.add(DateTime.utc_now(), 7200, :second),
        state: :active
      }

      refute Lease.expired?(lease)
    end
  end

  describe "deprecated?/1" do
    test "returns true when preferred expired but still valid" do
      now = DateTime.utc_now()

      lease = %Lease{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        pool_name: "pool1",
        starts_at: DateTime.add(now, -7200, :second),
        preferred_until: DateTime.add(now, -1, :second),
        valid_until: DateTime.add(now, 3600, :second),
        state: :active
      }

      assert Lease.deprecated?(lease)
    end

    test "returns false when both still valid" do
      now = DateTime.utc_now()

      lease = %Lease{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        pool_name: "pool1",
        starts_at: now,
        preferred_until: DateTime.add(now, 3600, :second),
        valid_until: DateTime.add(now, 7200, :second),
        state: :active
      }

      refute Lease.deprecated?(lease)
    end
  end

  describe "active?/1" do
    test "returns true for active non-expired lease" do
      lease = %Lease{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        pool_name: "pool1",
        starts_at: DateTime.utc_now(),
        preferred_until: DateTime.add(DateTime.utc_now(), 3600, :second),
        valid_until: DateTime.add(DateTime.utc_now(), 7200, :second),
        state: :active
      }

      assert Lease.active?(lease)
    end

    test "returns false for released lease" do
      lease = %Lease{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        pool_name: "pool1",
        starts_at: DateTime.utc_now(),
        preferred_until: DateTime.add(DateTime.utc_now(), 3600, :second),
        valid_until: DateTime.add(DateTime.utc_now(), 7200, :second),
        state: :released
      }

      refute Lease.active?(lease)
    end

    test "returns false for expired active lease" do
      lease = %Lease{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        pool_name: "pool1",
        starts_at: DateTime.add(DateTime.utc_now(), -7200, :second),
        preferred_until: DateTime.add(DateTime.utc_now(), -3600, :second),
        valid_until: DateTime.add(DateTime.utc_now(), -1, :second),
        state: :active
      }

      refute Lease.active?(lease)
    end
  end

  describe "release/1 and decline/1" do
    setup do
      lease =
        Lease.create(@valid_ip, @valid_duid, @valid_iaid, "pool1", %{preferred: 3600, valid: 7200})

      %{lease: lease}
    end

    test "release sets state to :released", %{lease: lease} do
      assert Lease.release(lease).state == :released
    end

    test "decline sets state to :declined", %{lease: lease} do
      assert Lease.decline(lease).state == :declined
    end
  end

  describe "renew/2" do
    test "resets lifetimes and state" do
      lease = %Lease{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        pool_name: "pool1",
        starts_at: DateTime.add(DateTime.utc_now(), -7200, :second),
        preferred_until: DateTime.add(DateTime.utc_now(), -3600, :second),
        valid_until: DateTime.add(DateTime.utc_now(), -1, :second),
        state: :active
      }

      renewed = Lease.renew(lease, %{preferred: 1800, valid: 3600})
      assert renewed.state == :active
      assert DateTime.after?(renewed.preferred_until, DateTime.utc_now())
      assert DateTime.after?(renewed.valid_until, DateTime.utc_now())
    end
  end

  describe "validate/1" do
    test "returns :ok for valid lease" do
      lease =
        Lease.create(@valid_ip, @valid_duid, @valid_iaid, "pool1", %{preferred: 3600, valid: 7200})

      assert :ok = Lease.validate(lease)
    end

    test "returns error for invalid IP" do
      lease = %Lease{
        ip: "not-an-ip",
        duid: @valid_duid,
        iaid: @valid_iaid,
        pool_name: "pool1",
        starts_at: DateTime.utc_now(),
        preferred_until: DateTime.add(DateTime.utc_now(), 3600, :second),
        valid_until: DateTime.add(DateTime.utc_now(), 7200, :second)
      }

      assert {:error, _} = Lease.validate(lease)
    end

    test "returns error for timestamps where start > valid_until" do
      now = DateTime.utc_now()

      lease = %Lease{
        ip: @valid_ip,
        duid: @valid_duid,
        iaid: @valid_iaid,
        pool_name: "pool1",
        starts_at: DateTime.add(now, 7200, :second),
        preferred_until: DateTime.add(now, 3600, :second),
        valid_until: now
      }

      assert {:error, _} = Lease.validate(lease)
    end
  end

  describe "lease_key/1" do
    test "returns {duid, iaid} tuple" do
      lease =
        Lease.create(@valid_ip, @valid_duid, @valid_iaid, "pool1", %{preferred: 3600, valid: 7200})

      assert {@valid_duid, @valid_iaid} = Lease.lease_key(lease)
    end
  end

  describe "TOML round-trip" do
    test "to_toml_map then from_toml_map preserves data" do
      lease =
        Lease.create(@valid_ip, @valid_duid, @valid_iaid, "pool1", %{preferred: 3600, valid: 7200})

      toml = Lease.to_toml_map(lease)

      assert is_map(toml)
      assert toml["pool_name"] == "pool1"
      assert toml["state"] == "active"
      assert is_binary(toml["ip"])
      assert is_binary(toml["duid"])
      assert is_integer(toml["iaid"])

      assert {:ok, restored} = Lease.from_toml_map(toml)
      assert restored.ip == lease.ip
      assert restored.iaid == lease.iaid
      assert restored.pool_name == lease.pool_name
      assert restored.state == lease.state
    end
  end
end
