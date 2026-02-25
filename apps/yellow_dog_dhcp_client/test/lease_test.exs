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
