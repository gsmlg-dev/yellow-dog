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
end
