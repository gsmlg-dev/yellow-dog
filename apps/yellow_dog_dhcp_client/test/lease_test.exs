defmodule YellowDog.DhcpClient.LeaseTest do
  use ExUnit.Case, async: true

  alias YellowDog.DhcpClient.Lease

  defp make_lease(overrides) do
    defaults = %{
      ip: {192, 168, 1, 100},
      subnet_mask: {255, 255, 255, 0},
      router: {192, 168, 1, 1},
      dns_servers: [{8, 8, 8, 8}],
      server_ip: {192, 168, 1, 1},
      server_mac: nil,
      lease_time: 3600,
      t1: 1800,
      t2: 3150,
      domain_name: nil,
      ntp_servers: [],
      mtu: nil,
      vendor_options: %{},
      control_url: nil,
      control_url_fallback: nil,
      auth_token: nil,
      server_id: nil,
      cluster_id: nil,
      yellowdog_server: false,
      obtained_at: DateTime.utc_now(),
      xid: 0x12345678,
      raw_options: %{}
    }

    struct(Lease, Map.merge(defaults, overrides))
  end

  # ── expired?/1 ──

  describe "expired?/1" do
    test "returns false for fresh lease" do
      lease = make_lease(%{lease_time: 3600, obtained_at: DateTime.utc_now()})
      refute Lease.expired?(lease)
    end

    test "returns true for old lease" do
      past = DateTime.add(DateTime.utc_now(), -7200, :second)
      lease = make_lease(%{lease_time: 3600, obtained_at: past})
      assert Lease.expired?(lease)
    end

    test "returns true for lease that expired exactly now" do
      # Lease obtained lease_time seconds ago should be expired (not :lt)
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      lease = make_lease(%{lease_time: 3600, obtained_at: past})
      assert Lease.expired?(lease)
    end

    test "returns false for lease with long expiry" do
      lease = make_lease(%{lease_time: 86_400, obtained_at: DateTime.utc_now()})
      refute Lease.expired?(lease)
    end

    test "returns true for lease with 1 second lifetime obtained 2 seconds ago" do
      past = DateTime.add(DateTime.utc_now(), -2, :second)
      lease = make_lease(%{lease_time: 1, obtained_at: past})
      assert Lease.expired?(lease)
    end

    test "returns true for lease with nil obtained_at (defensive)" do
      lease = %Lease{obtained_at: nil, lease_time: 3600}
      assert Lease.expired?(lease)
    end

    test "returns true for lease with nil lease_time (defensive)" do
      lease = %Lease{obtained_at: DateTime.utc_now(), lease_time: nil}
      assert Lease.expired?(lease)
    end

    test "returns true for lease with zero lease_time (defensive)" do
      lease = %Lease{obtained_at: DateTime.utc_now(), lease_time: 0}
      assert Lease.expired?(lease)
    end
  end

  # ── t1_elapsed?/1 ──

  describe "t1_elapsed?/1" do
    test "returns false when T1 has not elapsed" do
      lease = make_lease(%{t1: 1800, obtained_at: DateTime.utc_now()})
      refute Lease.t1_elapsed?(lease)
    end

    test "returns true when T1 has elapsed" do
      past = DateTime.add(DateTime.utc_now(), -2000, :second)
      lease = make_lease(%{t1: 1800, obtained_at: past})
      assert Lease.t1_elapsed?(lease)
    end

    test "returns true when T1 is exactly now" do
      past = DateTime.add(DateTime.utc_now(), -1800, :second)
      lease = make_lease(%{t1: 1800, obtained_at: past})
      assert Lease.t1_elapsed?(lease)
    end

    test "returns true for lease with nil t1 (defensive)" do
      lease = make_lease(%{t1: nil})
      assert Lease.t1_elapsed?(lease)
    end
  end

  # ── t2_elapsed?/1 ──

  describe "t2_elapsed?/1" do
    test "returns false when T2 has not elapsed" do
      lease = make_lease(%{t2: 3150, obtained_at: DateTime.utc_now()})
      refute Lease.t2_elapsed?(lease)
    end

    test "returns true when T2 has elapsed" do
      past = DateTime.add(DateTime.utc_now(), -4000, :second)
      lease = make_lease(%{t2: 3150, obtained_at: past})
      assert Lease.t2_elapsed?(lease)
    end

    test "returns true when T2 is exactly now" do
      past = DateTime.add(DateTime.utc_now(), -3150, :second)
      lease = make_lease(%{t2: 3150, obtained_at: past})
      assert Lease.t2_elapsed?(lease)
    end

    test "returns true for lease with nil t2 (defensive)" do
      lease = make_lease(%{t2: nil})
      assert Lease.t2_elapsed?(lease)
    end
  end

  # ── expires_at/1 ──

  describe "expires_at/1" do
    test "returns correct expiry DateTime" do
      obtained = ~U[2026-01-01 00:00:00Z]
      lease = make_lease(%{obtained_at: obtained, lease_time: 3600})
      assert Lease.expires_at(lease) == ~U[2026-01-01 01:00:00Z]
    end

    test "returns nil when lease_time is nil" do
      lease = %Lease{obtained_at: DateTime.utc_now(), lease_time: nil}
      assert Lease.expires_at(lease) == nil
    end

    test "returns nil when obtained_at is nil" do
      lease = %Lease{obtained_at: nil, lease_time: 3600}
      assert Lease.expires_at(lease) == nil
    end

    test "returns nil when lease_time is 0" do
      lease = %Lease{obtained_at: DateTime.utc_now(), lease_time: 0}
      assert Lease.expires_at(lease) == nil
    end
  end

  # ── time_remaining/1 ──

  describe "time_remaining/1" do
    test "returns positive seconds for fresh lease" do
      lease = make_lease(%{lease_time: 3600, obtained_at: DateTime.utc_now()})
      remaining = Lease.time_remaining(lease)
      assert is_integer(remaining)
      assert remaining > 3590
      assert remaining <= 3600
    end

    test "returns 0 for expired lease" do
      past = DateTime.add(DateTime.utc_now(), -7200, :second)
      lease = make_lease(%{lease_time: 3600, obtained_at: past})
      assert Lease.time_remaining(lease) == 0
    end

    test "returns nil when lease data is incomplete" do
      lease = %Lease{obtained_at: nil, lease_time: nil}
      assert Lease.time_remaining(lease) == nil
    end
  end

  # ── valid?/1 ──

  describe "valid?/1" do
    test "returns true for fresh lease with valid IP" do
      lease =
        make_lease(%{ip: {192, 168, 1, 100}, lease_time: 3600, obtained_at: DateTime.utc_now()})

      assert Lease.valid?(lease)
    end

    test "returns false for zero IP" do
      lease = make_lease(%{ip: {0, 0, 0, 0}, lease_time: 3600, obtained_at: DateTime.utc_now()})
      refute Lease.valid?(lease)
    end

    test "returns false for expired lease" do
      past = DateTime.add(DateTime.utc_now(), -7200, :second)
      lease = make_lease(%{ip: {192, 168, 1, 100}, lease_time: 3600, obtained_at: past})
      refute Lease.valid?(lease)
    end

    test "returns false for nil lease_time" do
      lease = %Lease{ip: {192, 168, 1, 100}, obtained_at: DateTime.utc_now(), lease_time: nil}
      refute Lease.valid?(lease)
    end

    test "returns false for nil obtained_at" do
      lease = %Lease{ip: {192, 168, 1, 100}, obtained_at: nil, lease_time: 3600}
      refute Lease.valid?(lease)
    end

    test "returns false for zero lease_time" do
      lease = %Lease{ip: {192, 168, 1, 100}, obtained_at: DateTime.utc_now(), lease_time: 0}
      refute Lease.valid?(lease)
    end
  end

  # ── t1_at/1 ──

  describe "t1_at/1" do
    test "returns correct T1 DateTime" do
      obtained = ~U[2026-01-01 00:00:00Z]
      lease = make_lease(%{obtained_at: obtained, t1: 1800})
      assert Lease.t1_at(lease) == ~U[2026-01-01 00:30:00Z]
    end

    test "returns nil when t1 is nil" do
      lease = %Lease{obtained_at: DateTime.utc_now(), t1: nil}
      assert Lease.t1_at(lease) == nil
    end

    test "returns nil when obtained_at is nil" do
      lease = %Lease{obtained_at: nil, t1: 1800}
      assert Lease.t1_at(lease) == nil
    end
  end

  # ── t2_at/1 ──

  describe "t2_at/1" do
    test "returns correct T2 DateTime" do
      obtained = ~U[2026-01-01 00:00:00Z]
      lease = make_lease(%{obtained_at: obtained, t2: 3150})
      assert Lease.t2_at(lease) == ~U[2026-01-01 00:52:30Z]
    end

    test "returns nil when t2 is nil" do
      lease = %Lease{obtained_at: DateTime.utc_now(), t2: nil}
      assert Lease.t2_at(lease) == nil
    end

    test "returns nil when obtained_at is nil" do
      lease = %Lease{obtained_at: nil, t2: 3150}
      assert Lease.t2_at(lease) == nil
    end
  end

  # ── prefix_length/1 ──

  describe "prefix_length/1" do
    test "converts /24 subnet mask" do
      lease = make_lease(%{subnet_mask: {255, 255, 255, 0}})
      assert Lease.prefix_length(lease) == 24
    end

    test "converts /16 subnet mask" do
      lease = make_lease(%{subnet_mask: {255, 255, 0, 0}})
      assert Lease.prefix_length(lease) == 16
    end

    test "converts /8 subnet mask" do
      lease = make_lease(%{subnet_mask: {255, 0, 0, 0}})
      assert Lease.prefix_length(lease) == 8
    end

    test "converts /25 subnet mask" do
      lease = make_lease(%{subnet_mask: {255, 255, 255, 128}})
      assert Lease.prefix_length(lease) == 25
    end

    test "converts /32 subnet mask" do
      lease = make_lease(%{subnet_mask: {255, 255, 255, 255}})
      assert Lease.prefix_length(lease) == 32
    end

    test "converts /0 subnet mask" do
      lease = make_lease(%{subnet_mask: {0, 0, 0, 0}})
      assert Lease.prefix_length(lease) == 0
    end

    test "converts /20 subnet mask" do
      lease = make_lease(%{subnet_mask: {255, 255, 240, 0}})
      assert Lease.prefix_length(lease) == 20
    end

    test "converts /30 subnet mask (point-to-point)" do
      lease = make_lease(%{subnet_mask: {255, 255, 255, 252}})
      assert Lease.prefix_length(lease) == 30
    end

    test "converts /12 subnet mask" do
      lease = make_lease(%{subnet_mask: {255, 240, 0, 0}})
      assert Lease.prefix_length(lease) == 12
    end
  end

  # ── struct defaults ──

  describe "struct defaults" do
    test "dns_servers defaults to empty list" do
      lease = %Lease{}
      assert lease.dns_servers == []
    end

    test "ntp_servers defaults to empty list" do
      lease = %Lease{}
      assert lease.ntp_servers == []
    end

    test "yellowdog_server defaults to false" do
      lease = %Lease{}
      assert lease.yellowdog_server == false
    end

    test "known_server defaults to false" do
      lease = %Lease{}
      assert lease.known_server == false
    end

    test "vendor_options defaults to empty map" do
      lease = %Lease{}
      assert lease.vendor_options == %{}
    end

    test "raw_options defaults to empty map" do
      lease = %Lease{}
      assert lease.raw_options == %{}
    end
  end
end
