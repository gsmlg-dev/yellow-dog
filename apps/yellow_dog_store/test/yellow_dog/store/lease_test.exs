defmodule YellowDog.Store.LeaseTest do
  use ExUnit.Case, async: false

  @moduletag :store_integration

  alias YellowDog.Store.Lease

  setup do
    YellowDog.StoreHelper.setup_store()
    :ok
  end

  describe "offer/4" do
    test "creates a lease in offered state" do
      assert :ok = Lease.offer(:v4, "aa:bb:cc:dd:ee:ff", {192, 168, 1, 10})

      assert {:ok, lease} = Lease.get(:v4, "aa:bb:cc:dd:ee:ff")
      assert lease.state == :offered
      assert lease.ip == {192, 168, 1, 10}
      assert lease.version == 1
    end

    test "offer with options sets hostname, subnet, and lease_duration" do
      assert :ok =
               Lease.offer(:v4, "aa:bb:cc:dd:ee:01", {192, 168, 1, 11},
                 hostname: "myhost",
                 subnet: "192.168.1.0/24",
                 lease_duration: 7200,
                 xid: 12345
               )

      assert {:ok, lease} = Lease.get(:v4, "aa:bb:cc:dd:ee:01")
      assert lease.hostname == "myhost"
      assert lease.subnet == "192.168.1.0/24"
      assert lease.lease_duration == 7200
      assert lease.xid == 12345
    end

    test "duplicate offer returns error" do
      Lease.offer(:v4, "aa:bb:cc:dd:ee:02", {192, 168, 1, 12})
      # Bind first to move out of :offered state
      Lease.bind(:v4, "aa:bb:cc:dd:ee:02", nil)

      assert {:error, :already_exists} =
               Lease.offer(:v4, "aa:bb:cc:dd:ee:02", {192, 168, 1, 13})
    end

    test "re-offer over existing offered lease succeeds" do
      Lease.offer(:v4, "aa:bb:cc:dd:ee:03", {192, 168, 1, 14})
      assert :ok = Lease.offer(:v4, "aa:bb:cc:dd:ee:03", {192, 168, 1, 15})
    end

    test "MAC normalization in offer" do
      assert :ok = Lease.offer(:v4, "AA-BB-CC-DD-EE-04", {192, 168, 1, 16})
      # Lookup with different MAC format should find the same lease
      assert {:ok, _lease} = Lease.get(:v4, "aa:bb:cc:dd:ee:04")
    end
  end

  describe "bind/3" do
    test "transitions offered to bound" do
      Lease.offer(:v4, "bb:00:00:00:00:01", {10, 0, 0, 1}, xid: 100)
      assert :ok = Lease.bind(:v4, "bb:00:00:00:00:01", 100)

      assert {:ok, lease} = Lease.get(:v4, "bb:00:00:00:00:01")
      assert lease.state == :bound
      assert lease.version == 2
    end

    test "bind with wrong xid fails" do
      Lease.offer(:v4, "bb:00:00:00:00:02", {10, 0, 0, 2}, xid: 100)

      assert {:error, :invalid_transition} = Lease.bind(:v4, "bb:00:00:00:00:02", 999)
    end

    test "bind on nonexistent lease fails" do
      assert {:error, :invalid_transition} = Lease.bind(:v4, "bb:00:00:00:00:99", 100)
    end
  end

  describe "renew/3" do
    test "transitions bound to renewing" do
      Lease.offer(:v4, "cc:00:00:00:00:01", {10, 0, 1, 1}, xid: 200)
      Lease.bind(:v4, "cc:00:00:00:00:01", 200)

      assert :ok = Lease.renew(:v4, "cc:00:00:00:00:01", 7200)

      assert {:ok, lease} = Lease.get(:v4, "cc:00:00:00:00:01")
      assert lease.state == :renewing
      assert lease.lease_duration == 7200
    end

    test "renew on offered lease fails" do
      Lease.offer(:v4, "cc:00:00:00:00:02", {10, 0, 1, 2})

      assert {:error, :invalid_transition} = Lease.renew(:v4, "cc:00:00:00:00:02", 3600)
    end
  end

  describe "release/2" do
    test "marks lease as released" do
      Lease.offer(:v4, "dd:00:00:00:00:01", {10, 0, 2, 1}, xid: 300)
      Lease.bind(:v4, "dd:00:00:00:00:01", 300)

      assert :ok = Lease.release(:v4, "dd:00:00:00:00:01")

      assert {:ok, lease} = Lease.get(:v4, "dd:00:00:00:00:01")
      assert lease.state == :released
    end

    test "release on nonexistent lease fails" do
      assert {:error, :invalid_transition} = Lease.release(:v4, "dd:00:00:00:00:99")
    end
  end

  describe "decline/2" do
    test "marks lease as declined" do
      Lease.offer(:v4, "ee:00:00:00:00:01", {10, 0, 3, 1}, xid: 400)
      Lease.bind(:v4, "ee:00:00:00:00:01", 400)

      assert :ok = Lease.decline(:v4, "ee:00:00:00:00:01")

      assert {:ok, lease} = Lease.get(:v4, "ee:00:00:00:00:01")
      assert lease.state == :declined
    end
  end

  describe "by_ip/1" do
    test "finds v4 lease by IP" do
      Lease.offer(:v4, "ff:00:00:00:00:01", {172, 16, 0, 1})

      assert {:ok, {:v4, _client_id, lease}} = Lease.by_ip({172, 16, 0, 1})
      assert lease.ip == {172, 16, 0, 1}
    end

    test "returns not_found for unknown IP" do
      assert {:error, :not_found} = Lease.by_ip({255, 255, 255, 255})
    end
  end

  describe "get/2" do
    test "returns not_found for nonexistent lease" do
      assert {:error, :not_found} = Lease.get(:v4, "00:00:00:00:00:00")
    end
  end

  describe "list_by_protocol/1" do
    test "lists all v4 leases" do
      Lease.offer(:v4, "11:00:00:00:00:01", {10, 10, 0, 1})
      Lease.offer(:v4, "11:00:00:00:00:02", {10, 10, 0, 2})

      assert {:ok, leases} = Lease.list_by_protocol(:v4)
      assert length(leases) >= 2
    end
  end

  describe "DHCPv6 lease lifecycle" do
    test "offer and bind v6 lease using DUID" do
      duid = "00:01:00:01:2a:3b:4c:5d:aa:bb:cc:dd:ee:ff"

      assert :ok =
               Lease.offer(:v6, duid, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1},
                 xid: 500,
                 lease_duration: 7200
               )

      assert {:ok, lease} = Lease.get(:v6, duid)
      assert lease.state == :offered
      assert lease.ip == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

      assert :ok = Lease.bind(:v6, duid, 500)
      assert {:ok, bound} = Lease.get(:v6, duid)
      assert bound.state == :bound
    end

    test "v6 renew and release" do
      duid = "00:01:00:01:2a:3b:4c:5d:11:22:33:44:55:66"
      Lease.offer(:v6, duid, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 2}, xid: 501)
      Lease.bind(:v6, duid, 501)

      assert :ok = Lease.renew(:v6, duid, 14400)
      assert {:ok, lease} = Lease.get(:v6, duid)
      assert lease.state == :renewing
      assert lease.lease_duration == 14400

      assert :ok = Lease.release(:v6, duid)
      assert {:ok, released} = Lease.get(:v6, duid)
      assert released.state == :released
    end

    test "DUID normalization in offer" do
      duid = "00-01-00-01-2A-3B-4C-5D-AA-BB-CC-DD-EE-FF"
      assert :ok = Lease.offer(:v6, duid, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 3})
      # Lookup with normalized format
      assert {:ok, _lease} =
               Lease.get(:v6, "00:01:00:01:2a:3b:4c:5d:aa:bb:cc:dd:ee:ff")
    end

    test "list_by_protocol returns v6 leases" do
      duid = "00:01:00:01:ff:ff:ff:ff:11:22:33:44:55:66"
      Lease.offer(:v6, duid, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 10})

      assert {:ok, leases} = Lease.list_by_protocol(:v6)
      assert length(leases) >= 1
    end
  end

  describe "cross-protocol by_ip" do
    test "by_ip finds v6 lease" do
      duid = "00:01:00:01:aa:bb:cc:dd:11:22:33:44:55:66"
      ip6 = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 99}
      Lease.offer(:v6, duid, ip6)

      assert {:ok, {:v6, _id, lease}} = Lease.by_ip(ip6)
      assert lease.ip == ip6
    end

    test "by_ip searches both v4 and v6 prefixes" do
      mac = "a1:b2:c3:d4:e5:f6"
      duid = "00:01:00:01:cc:dd:ee:ff:a1:b2:c3:d4:e5:f6"
      ip4 = {10, 0, 0, 50}
      ip6 = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 50}

      Lease.offer(:v4, mac, ip4)
      Lease.offer(:v6, duid, ip6)

      assert {:ok, {:v4, _, _}} = Lease.by_ip(ip4)
      assert {:ok, {:v6, _, _}} = Lease.by_ip(ip6)
    end
  end

  describe "list_by_subnet/1" do
    test "filters leases by subnet" do
      Lease.offer(:v4, "22:00:00:00:00:01", {10, 20, 0, 1}, subnet: "10.20.0.0/24")
      Lease.offer(:v4, "22:00:00:00:00:02", {10, 30, 0, 1}, subnet: "10.30.0.0/24")

      assert {:ok, leases} = Lease.list_by_subnet("10.20.0.0/24")
      assert Enum.all?(leases, fn l -> l.subnet == "10.20.0.0/24" end)
    end
  end
end
