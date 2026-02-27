defmodule YellowDog.DhcpClient.OSIntegration.HookNMTest do
  use ExUnit.Case, async: true

  alias YellowDog.DhcpClient.OSIntegration.HookNM
  alias YellowDog.DhcpClient.Lease

  defp test_lease(overrides \\ %{}) do
    Map.merge(
      %Lease{
        ip: {192, 168, 1, 100},
        subnet_mask: {255, 255, 255, 0},
        router: {192, 168, 1, 1},
        dns_servers: [{8, 8, 8, 8}, {8, 8, 4, 4}],
        server_ip: {192, 168, 1, 1},
        lease_time: 3600,
        t1: 1800,
        t2: 3150,
        mtu: nil,
        domain_name: "example.local",
        ntp_servers: [],
        vendor_options: %{},
        yellowdog_server: false,
        control_url: nil,
        obtained_at: ~U[2026-01-01 00:00:00Z],
        xid: 0x1234,
        raw_options: %{}
      },
      overrides
    )
  end

  describe "apply_routes/2" do
    test "is a no-op returning :ok" do
      assert :ok = HookNM.apply_routes("test0", test_lease())
    end
  end

  describe "apply_dns/2" do
    test "is a no-op returning :ok" do
      assert :ok = HookNM.apply_dns("test0", test_lease())
    end
  end

  describe "deconfigure/1" do
    test "returns :ok even when no lease file exists" do
      assert :ok = HookNM.deconfigure("nonexistent_hook_test_iface")
    end

    test "removes the lease JSON file if it exists" do
      iface = "test_deconfig_#{System.unique_integer([:positive])}"
      path = Path.join("/tmp", "yd-dhcp-#{iface}.json")
      File.write!(path, "{}")
      on_exit(fn -> File.rm(path) end)

      assert :ok = HookNM.deconfigure(iface)
      refute File.exists?(path)
    end
  end

  describe "apply_lease/2" do
    test "writes JSON lease file and emits telemetry" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-hook-apply-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :os, :apply],
        fn _event, measurements, metadata, _config ->
          send(self_pid, {:telemetry_hook, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-hook-apply-#{inspect(ref)}") end)

      lease = test_lease()
      iface = "test_hook_#{System.unique_integer([:positive])}"
      result = HookNM.apply_lease(iface, lease)

      # Clean up the written file
      lease_path = Path.join("/tmp", "yd-dhcp-#{iface}.json")
      on_exit(fn -> File.rm(lease_path) end)

      assert result == :ok

      # Verify the JSON file was written
      assert {:ok, content} = File.read(lease_path)
      assert {:ok, data} = Jason.decode(content)
      assert data["interface"] == iface
      assert data["ip"] == "192.168.1.100"
      assert data["subnet_mask"] == "255.255.255.0"
      assert data["prefix_length"] == 24
      assert data["router"] == "192.168.1.1"
      assert data["dns_servers"] == ["8.8.8.8", "8.8.4.4"]
      assert data["domain_name"] == "example.local"
      assert data["lease_time"] == 3600
      assert data["yellowdog_server"] == false

      # Verify telemetry was emitted
      assert_receive {:telemetry_hook, %{duration_ms: _}, %{action: :configure}}, 1000
    end

    test "handles nil router in JSON output" do
      lease = test_lease(%{router: nil})
      iface = "test_hook_nil_router_#{System.unique_integer([:positive])}"
      lease_path = Path.join("/tmp", "yd-dhcp-#{iface}.json")
      on_exit(fn -> File.rm(lease_path) end)

      assert :ok = HookNM.apply_lease(iface, lease)

      {:ok, content} = File.read(lease_path)
      {:ok, data} = Jason.decode(content)
      assert data["router"] == nil
    end

    test "includes NTP servers and MTU in JSON output" do
      lease =
        test_lease(%{
          ntp_servers: [{129, 6, 15, 28}, {129, 6, 15, 29}],
          mtu: 9000
        })

      iface = "test_hook_ntp_mtu_#{System.unique_integer([:positive])}"
      lease_path = Path.join("/tmp", "yd-dhcp-#{iface}.json")
      on_exit(fn -> File.rm(lease_path) end)

      assert :ok = HookNM.apply_lease(iface, lease)

      {:ok, content} = File.read(lease_path)
      {:ok, data} = Jason.decode(content)
      assert data["ntp_servers"] == ["129.6.15.28", "129.6.15.29"]
      assert data["mtu"] == 9000
    end
  end
end
