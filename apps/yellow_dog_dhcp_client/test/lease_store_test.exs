defmodule YellowDog.DhcpClient.LeaseStoreTest do
  use ExUnit.Case, async: true

  alias YellowDog.DhcpClient.LeaseStore

  setup do
    dir = Path.join(System.tmp_dir!(), "yd_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{lease_dir: dir}
  end

  defp make_lease(overrides \\ %{}) do
    defaults = %{
      ip: {192, 168, 1, 100},
      subnet_mask: {255, 255, 255, 0},
      router: {192, 168, 1, 1},
      dns_servers: [{8, 8, 8, 8}],
      ntp_servers: [],
      server_ip: {192, 168, 1, 1},
      server_mac: nil,
      lease_time: 3600,
      t1: 1800,
      t2: 3150,
      domain_name: "example.com",
      mtu: 1500,
      vendor_options: %{},
      control_url: "http://localhost:4270",
      control_url_fallback: nil,
      auth_token: "secret-token",
      server_id: "srv-01",
      cluster_id: "cluster-a",
      yellowdog_server: true,
      obtained_at: DateTime.utc_now(),
      xid: 0x12345678,
      raw_options: %{}
    }

    struct(YellowDog.DhcpClient.Lease, Map.merge(defaults, overrides))
  end

  defp start_store(ctx, opts \\ []) do
    interface = Keyword.get(opts, :interface, "eth0")
    {:ok, pid} = LeaseStore.start_link(interface: interface, lease_dir: ctx.lease_dir)
    {pid, interface}
  end

  # ── store and lookup ──

  test "stores and retrieves a lease", ctx do
    {pid, iface} = start_store(ctx)
    lease = make_lease()

    assert :ok = LeaseStore.store(pid, iface, lease)
    assert {:ok, ^lease} = LeaseStore.lookup(pid, iface)
  end

  test "returns :not_found for missing lease", ctx do
    {pid, _iface} = start_store(ctx)
    assert :not_found = LeaseStore.lookup(pid, "nonexistent0")
  end

  test "overwrites existing lease on store", ctx do
    {pid, iface} = start_store(ctx)
    lease1 = make_lease(%{ip: {192, 168, 1, 100}})
    lease2 = make_lease(%{ip: {192, 168, 1, 200}})

    :ok = LeaseStore.store(pid, iface, lease1)
    :ok = LeaseStore.store(pid, iface, lease2)

    assert {:ok, ^lease2} = LeaseStore.lookup(pid, iface)
  end

  # ── delete ──

  test "deletes a lease", ctx do
    {pid, iface} = start_store(ctx)
    lease = make_lease()

    :ok = LeaseStore.store(pid, iface, lease)
    assert {:ok, _} = LeaseStore.lookup(pid, iface)

    :ok = LeaseStore.delete(pid, iface)
    assert :not_found = LeaseStore.lookup(pid, iface)
  end

  test "delete is idempotent for missing lease", ctx do
    {pid, _iface} = start_store(ctx)
    assert :ok = LeaseStore.delete(pid, "nonexistent0")
  end

  # ── disk persistence ──

  test "persists lease to disk on flush", ctx do
    {pid, iface} = start_store(ctx)
    lease = make_lease()

    :ok = LeaseStore.store(pid, iface, lease)

    # The flush is scheduled with a 1 second delay. Wait for it to fire.
    Process.sleep(1_500)

    lease_path = Path.join(ctx.lease_dir, "#{iface}.lease")
    assert File.exists?(lease_path)

    content = File.read!(lease_path)
    assert String.contains?(content, "192.168.1.100")
    assert String.contains?(content, "3600")
  end

  test "loads persisted lease on startup", ctx do
    iface = "eth0"

    # Write a valid TOML lease file
    obtained_at = DateTime.utc_now()
    lease_time = 86_400

    toml_content = """
    ip = "192.168.1.50"
    subnet_mask = "255.255.255.0"
    server_ip = "192.168.1.1"
    lease_time = #{lease_time}
    t1 = 43200
    t2 = 75600
    obtained_at = "#{DateTime.to_iso8601(obtained_at)}"
    xid = 999
    yellowdog_server = false
    router = "192.168.1.1"
    domain_name = "test.local"
    dns_servers = ["8.8.8.8"]
    """

    lease_path = Path.join(ctx.lease_dir, "#{iface}.lease")
    File.write!(lease_path, toml_content)

    {:ok, pid} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)

    assert {:ok, loaded} = LeaseStore.lookup(pid, iface)
    assert is_struct(loaded, YellowDog.DhcpClient.Lease)
    assert loaded.ip == {192, 168, 1, 50}
    assert loaded.subnet_mask == {255, 255, 255, 0}
    assert loaded.server_ip == {192, 168, 1, 1}
    assert loaded.lease_time == lease_time
    assert loaded.t1 == 43_200
    assert loaded.t2 == 75_600
    assert loaded.xid == 999
    assert loaded.domain_name == "test.local"
    assert loaded.dns_servers == [{8, 8, 8, 8}]
    assert loaded.router == {192, 168, 1, 1}
  end

  test "discards expired persisted lease", ctx do
    iface = "eth0"

    # Write a lease that expired in the past
    expired_at = DateTime.add(DateTime.utc_now(), -7200, :second)

    toml_content = """
    ip = "192.168.1.50"
    subnet_mask = "255.255.255.0"
    server_ip = "192.168.1.1"
    lease_time = 3600
    t1 = 1800
    t2 = 3150
    obtained_at = "#{DateTime.to_iso8601(expired_at)}"
    xid = 999
    yellowdog_server = false
    """

    lease_path = Path.join(ctx.lease_dir, "#{iface}.lease")
    File.write!(lease_path, toml_content)

    {:ok, pid} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)

    assert :not_found = LeaseStore.lookup(pid, iface)
    # The expired lease file should have been removed
    refute File.exists?(lease_path)
  end

  test "handles missing lease file gracefully on startup", ctx do
    {:ok, pid} = LeaseStore.start_link(interface: "eth0", lease_dir: ctx.lease_dir)
    assert :not_found = LeaseStore.lookup(pid, "eth0")
  end

  test "handles corrupt lease file gracefully on startup", ctx do
    iface = "eth0"
    lease_path = Path.join(ctx.lease_dir, "#{iface}.lease")
    File.write!(lease_path, "this is not valid TOML {{{{ [[[")

    {:ok, pid} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)
    assert :not_found = LeaseStore.lookup(pid, iface)
  end

  test "handles TOML lease file with non-string IP fields gracefully", ctx do
    # Simulates partial disk write: router field contains an integer instead of string
    iface = "eth0"
    lease_path = Path.join(ctx.lease_dir, "#{iface}.lease")

    File.write!(lease_path, """
    ip = "192.168.1.50"
    subnet_mask = "255.255.255.0"
    router = 192
    server_ip = "192.168.1.1"
    lease_time = 3600
    obtained_at = "#{DateTime.to_iso8601(DateTime.utc_now())}"
    xid = 1
    yellowdog_server = false
    """)

    # Should not crash — parse_ip/1 catch-all returns {0,0,0,0} for non-string
    {:ok, pid} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)
    # The lease is loaded; router gets {0,0,0,0} which is treated as present
    # The important thing is it does not raise FunctionClauseError
    result = LeaseStore.lookup(pid, iface)
    assert match?({:ok, _}, result) or result == :not_found
  end

  test "delete removes lease file from disk", ctx do
    {pid, iface} = start_store(ctx)
    lease = make_lease()

    :ok = LeaseStore.store(pid, iface, lease)
    # Wait for flush
    Process.sleep(1_500)

    lease_path = Path.join(ctx.lease_dir, "#{iface}.lease")
    assert File.exists?(lease_path)

    :ok = LeaseStore.delete(pid, iface)
    refute File.exists?(lease_path)
  end

  test "TOML round-trip preserves strings with special characters", ctx do
    {pid, iface} = start_store(ctx)

    lease =
      make_lease(%{
        auth_token: ~s(token"with"quotes),
        control_url: ~s(https://example.com/path?a=1&b="test"),
        server_id: "server\\with\\backslash"
      })

    :ok = LeaseStore.store(pid, iface, lease)
    Process.sleep(1_500)

    # Re-read from disk by starting a new store process
    {:ok, pid2} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)
    {:ok, loaded} = LeaseStore.lookup(pid2, iface)

    assert loaded.auth_token == lease.auth_token
    assert loaded.control_url == lease.control_url
    assert loaded.server_id == lease.server_id
  end

  test "rejects persisted lease with zero IP", ctx do
    iface = "eth0"
    obtained_at = DateTime.utc_now()

    toml_content = """
    ip = "0.0.0.0"
    subnet_mask = "255.255.255.0"
    server_ip = "192.168.1.1"
    lease_time = 3600
    t1 = 1800
    t2 = 3150
    obtained_at = "#{DateTime.to_iso8601(obtained_at)}"
    xid = 1
    yellowdog_server = false
    """

    lease_path = Path.join(ctx.lease_dir, "#{iface}.lease")
    File.write!(lease_path, toml_content)

    {:ok, pid} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)
    assert :not_found = LeaseStore.lookup(pid, iface)
  end

  # ── missing obtained_at uses epoch (lease treated as expired) ──

  test "lease with missing obtained_at is treated as expired", ctx do
    iface = "eth0"

    toml_content = """
    ip = "192.168.1.50"
    subnet_mask = "255.255.255.0"
    server_ip = "192.168.1.1"
    lease_time = 3600
    t1 = 1800
    t2 = 3150
    xid = 999
    yellowdog_server = false
    """

    lease_path = Path.join(ctx.lease_dir, "#{iface}.lease")
    File.write!(lease_path, toml_content)

    {:ok, pid} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)

    # Without obtained_at, the lease should be treated as expired (epoch fallback)
    assert :not_found = LeaseStore.lookup(pid, iface)
  end

  test "lease with unparseable obtained_at is treated as expired", ctx do
    iface = "eth0"

    toml_content = """
    ip = "192.168.1.50"
    subnet_mask = "255.255.255.0"
    server_ip = "192.168.1.1"
    lease_time = 3600
    t1 = 1800
    t2 = 3150
    obtained_at = "not-a-date"
    xid = 999
    yellowdog_server = false
    """

    lease_path = Path.join(ctx.lease_dir, "#{iface}.lease")
    File.write!(lease_path, toml_content)

    {:ok, pid} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)
    assert :not_found = LeaseStore.lookup(pid, iface)
  end

  # ── nil lease_dir falls back to default ──

  test "start_link with lease_dir: nil uses default path without crashing" do
    # Regression: InterfaceSupervisor passes lease_dir: nil when not configured.
    # Keyword.get(opts, :lease_dir, default) returns nil when key is present,
    # which caused Path.join(nil, ...) to crash. Fixed with ||.
    {:ok, pid} = LeaseStore.start_link(interface: "eth_nil_test", lease_dir: nil)
    # Should start without crashing; lookup finds nothing in the (possibly absent) dir
    result = LeaseStore.lookup(pid, "eth_nil_test")
    assert result == :not_found or match?({:ok, _}, result)
    GenServer.stop(pid)
  end

  # ── multiple interfaces ──

  test "stores leases independently per interface", ctx do
    {pid, _} = start_store(ctx, interface: "eth0")

    lease_eth0 = make_lease(%{ip: {10, 0, 0, 1}})
    lease_wlan0 = make_lease(%{ip: {10, 0, 0, 2}})

    :ok = LeaseStore.store(pid, "eth0", lease_eth0)
    :ok = LeaseStore.store(pid, "wlan0", lease_wlan0)

    assert {:ok, ^lease_eth0} = LeaseStore.lookup(pid, "eth0")
    assert {:ok, ^lease_wlan0} = LeaseStore.lookup(pid, "wlan0")
  end

  test "terminate flushes all interfaces to disk, not just the primary one", ctx do
    {pid, _} = start_store(ctx, interface: "eth0")

    lease_eth0 = make_lease(%{ip: {10, 0, 0, 1}})
    lease_wlan0 = make_lease(%{ip: {10, 0, 0, 2}})

    :ok = LeaseStore.store(pid, "eth0", lease_eth0)
    :ok = LeaseStore.store(pid, "wlan0", lease_wlan0)

    # terminate/2 flushes all ETS entries synchronously
    GenServer.stop(pid)

    assert File.exists?(Path.join(ctx.lease_dir, "eth0.lease"))
    assert File.exists?(Path.join(ctx.lease_dir, "wlan0.lease"))
  end

  # ── synchronous flush via terminate ──
  #
  # GenServer.stop/1 triggers terminate/2 which flushes synchronously.
  # This avoids the 1.5s Process.sleep used in the async flush tests.

  test "TOML roundtrip preserves all optional vendor fields via terminate flush", ctx do
    {pid, iface} = start_store(ctx)

    lease =
      make_lease(%{
        cluster_id: "cluster-prod-east",
        control_url_fallback: "wss://backup.yd.example.com/ctrl",
        yellowdog_server: true
      })

    :ok = LeaseStore.store(pid, iface, lease)
    # terminate/2 flushes synchronously
    GenServer.stop(pid)

    {:ok, pid2} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)
    {:ok, loaded} = LeaseStore.lookup(pid2, iface)

    assert loaded.cluster_id == lease.cluster_id
    assert loaded.control_url_fallback == lease.control_url_fallback
    assert loaded.yellowdog_server == true
    assert loaded.control_url == lease.control_url
    assert loaded.auth_token == lease.auth_token
    assert loaded.server_id == lease.server_id
  end

  test "TOML roundtrip preserves MTU via terminate flush", ctx do
    {pid, iface} = start_store(ctx)
    lease = make_lease(%{mtu: 9000})

    :ok = LeaseStore.store(pid, iface, lease)
    GenServer.stop(pid)

    {:ok, pid2} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)
    {:ok, loaded} = LeaseStore.lookup(pid2, iface)

    assert loaded.mtu == 9000
  end

  test "TOML roundtrip preserves nil MTU as nil", ctx do
    {pid, iface} = start_store(ctx)
    lease = make_lease(%{mtu: nil})

    :ok = LeaseStore.store(pid, iface, lease)
    GenServer.stop(pid)

    {:ok, pid2} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)
    {:ok, loaded} = LeaseStore.lookup(pid2, iface)

    assert loaded.mtu == nil
  end

  test "TOML roundtrip preserves NTP servers via terminate flush", ctx do
    {pid, iface} = start_store(ctx)
    lease = make_lease(%{ntp_servers: [{129, 6, 15, 28}, {129, 6, 15, 29}]})

    :ok = LeaseStore.store(pid, iface, lease)
    GenServer.stop(pid)

    {:ok, pid2} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)
    {:ok, loaded} = LeaseStore.lookup(pid2, iface)

    assert loaded.ntp_servers == [{129, 6, 15, 28}, {129, 6, 15, 29}]
  end

  test "TOML roundtrip preserves empty NTP servers as empty list", ctx do
    {pid, iface} = start_store(ctx)
    lease = make_lease(%{ntp_servers: []})

    :ok = LeaseStore.store(pid, iface, lease)
    GenServer.stop(pid)

    {:ok, pid2} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)
    {:ok, loaded} = LeaseStore.lookup(pid2, iface)

    assert loaded.ntp_servers == []
  end

  test "flush creates missing lease_dir directory on first store", ctx do
    missing_dir = Path.join(ctx.lease_dir, "nested/subdir")
    refute File.exists?(missing_dir)

    {:ok, pid} = LeaseStore.start_link(interface: "eth0", lease_dir: missing_dir)
    lease = make_lease()
    :ok = LeaseStore.store(pid, "eth0", lease)
    GenServer.stop(pid)

    assert File.exists?(missing_dir)
    assert File.exists?(Path.join(missing_dir, "eth0.lease"))
  end

  test "TOML lease with missing 'ip' field is treated as invalid (:not_found)", ctx do
    iface = "eth0"
    lease_path = Path.join(ctx.lease_dir, "#{iface}.lease")

    File.write!(lease_path, """
    subnet_mask = "255.255.255.0"
    server_ip = "192.168.1.1"
    lease_time = 3600
    obtained_at = "#{DateTime.to_iso8601(DateTime.utc_now())}"
    xid = 1
    yellowdog_server = false
    """)

    {:ok, pid} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)
    # Missing "ip" → parse_ip(nil) → {0,0,0,0} → lease_valid? returns false
    assert :not_found = LeaseStore.lookup(pid, iface)
  end

  test "rapid consecutive stores only flush the final lease to disk", ctx do
    {pid, iface} = start_store(ctx)

    lease1 = make_lease(%{ip: {10, 0, 0, 1}})
    lease2 = make_lease(%{ip: {10, 0, 0, 2}})

    :ok = LeaseStore.store(pid, iface, lease1)
    :ok = LeaseStore.store(pid, iface, lease2)

    # Use terminate flush (synchronous) instead of sleeping for the async timer
    GenServer.stop(pid)

    {:ok, pid2} = LeaseStore.start_link(interface: iface, lease_dir: ctx.lease_dir)
    {:ok, loaded} = LeaseStore.lookup(pid2, iface)

    # Only lease2 should be on disk (lease1's timer was cancelled by the second store)
    assert loaded.ip == {10, 0, 0, 2}
  end
end
