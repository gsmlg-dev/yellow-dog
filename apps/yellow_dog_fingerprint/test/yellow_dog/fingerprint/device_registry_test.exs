defmodule YellowDog.Fingerprint.DeviceRegistryTest do
  use ExUnit.Case, async: false

  alias YellowDog.Fingerprint.DeviceRegistry
  alias YellowDog.Fingerprint.Types.Fingerprint

  # Use cryptographically random MACs to avoid collision with persisted device data.
  # DeviceRegistry normalizes MACs to lowercase, so we generate lowercase here too.
  # Bit 1 of first octet = 1 marks locally administered (avoids real OUI prefixes).
  defp unique_mac do
    :crypto.strong_rand_bytes(5)
    |> then(fn <<a, b, c, d, e>> -> [0x02, a, b, c, d, e] end)
    |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1, 16), 2, "0"))
    |> String.downcase()
  end

  defp sample_fingerprint do
    now = DateTime.utc_now()

    %Fingerprint{
      id: Fingerprint.compute_id(:dhcpv4, [1, 3, 6, 15], "MSFT 5.0"),
      protocol: :dhcpv4,
      parameter_list: [1, 3, 6, 15],
      vendor_class: "MSFT 5.0",
      hostname_pattern: nil,
      first_seen: now,
      last_seen: now,
      hit_count: 1
    }
  end

  defp sample_attrs(mac, overrides \\ []) do
    base = %{
      fingerprint: sample_fingerprint(),
      profile_id: nil,
      profile_confidence: 0,
      oui_vendor: "TestVendor",
      hostname: "testhost-#{mac}",
      source_ip: {192, 168, 1, 42},
      duid: nil
    }

    Map.merge(base, Map.new(overrides))
  end

  describe "DeviceRegistry is running" do
    test "the GenServer process is alive" do
      pid = Process.whereis(DeviceRegistry)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "update_device/2 and get/1" do
    test "creates new device when MAC not seen before" do
      mac = unique_mac()

      assert :not_found = DeviceRegistry.get(mac)

      DeviceRegistry.update_device(mac, sample_attrs(mac))
      DeviceRegistry.flush()

      assert {:ok, device} = DeviceRegistry.get(mac)
      assert device.mac == mac
    end

    test "device has correct hostname after creation" do
      mac = unique_mac()
      hostname = "myhost-#{mac}"

      DeviceRegistry.update_device(mac, sample_attrs(mac, hostname: hostname))
      DeviceRegistry.flush()

      {:ok, device} = DeviceRegistry.get(mac)
      assert device.hostname == hostname
    end

    test "device observation_count increments on repeat updates" do
      mac = unique_mac()

      DeviceRegistry.update_device(mac, sample_attrs(mac))
      # flush/0 is a GenServer.call — guarantees all prior casts are processed
      DeviceRegistry.flush()
      {:ok, device1} = DeviceRegistry.get(mac)
      assert device1.observation_count == 1

      DeviceRegistry.update_device(mac, sample_attrs(mac))
      DeviceRegistry.flush()
      {:ok, device2} = DeviceRegistry.get(mac)
      assert device2.observation_count == 2
    end

    test "device profile_id updates on second observation" do
      mac = unique_mac()

      DeviceRegistry.update_device(mac, sample_attrs(mac, profile_id: nil))
      DeviceRegistry.flush()

      DeviceRegistry.update_device(mac, sample_attrs(mac, profile_id: "windows-10", profile_confidence: 85))
      DeviceRegistry.flush()

      {:ok, device} = DeviceRegistry.get(mac)
      assert device.profile_id == "windows-10"
      assert device.profile_confidence == 85
    end

    test "get/1 returns :not_found for unknown MAC" do
      assert :not_found = DeviceRegistry.get("ff:ff:ff:ff:ff:ff")
    end
  end

  describe "list/0" do
    test "returns a list" do
      result = DeviceRegistry.list()
      assert is_list(result)
    end

    test "newly added device appears in list" do
      mac = unique_mac()

      before_count = length(DeviceRegistry.list())

      DeviceRegistry.update_device(mac, sample_attrs(mac))
      DeviceRegistry.flush()

      after_count = length(DeviceRegistry.list())
      assert after_count == before_count + 1
    end

    test "list is sorted by last_seen descending" do
      mac_a = unique_mac()
      mac_b = unique_mac()

      DeviceRegistry.update_device(mac_a, sample_attrs(mac_a))
      DeviceRegistry.flush()
      Process.sleep(5)
      DeviceRegistry.update_device(mac_b, sample_attrs(mac_b))
      DeviceRegistry.flush()

      devices = DeviceRegistry.list()
      macs = Enum.map(devices, & &1.mac)

      # mac_b is more recent, so it should appear before mac_a
      idx_a = Enum.find_index(macs, &(&1 == mac_a))
      idx_b = Enum.find_index(macs, &(&1 == mac_b))

      assert idx_b < idx_a
    end
  end

  describe "stats/0" do
    test "returns a map with expected keys" do
      stats = DeviceRegistry.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_devices)
      assert Map.has_key?(stats, :identified_devices)
      assert Map.has_key?(stats, :unknown_devices)
      assert Map.has_key?(stats, :avg_confidence)
    end

    test "total = identified + unknown" do
      stats = DeviceRegistry.stats()
      assert stats.total_devices == stats.identified_devices + stats.unknown_devices
    end

    test "total increases after adding device" do
      mac = unique_mac()
      before = DeviceRegistry.stats().total_devices

      DeviceRegistry.update_device(mac, sample_attrs(mac))
      DeviceRegistry.flush()

      after_stats = DeviceRegistry.stats()
      assert after_stats.total_devices == before + 1
    end

    test "identified count increases with identified device" do
      mac = unique_mac()
      before = DeviceRegistry.stats().identified_devices

      DeviceRegistry.update_device(mac, sample_attrs(mac, profile_id: "ios-15", profile_confidence: 90))
      DeviceRegistry.flush()

      after_stats = DeviceRegistry.stats()
      assert after_stats.identified_devices == before + 1
    end
  end

  describe "flush/0" do
    test "flush returns :ok" do
      assert :ok = DeviceRegistry.flush()
    end

    test "flush can be called multiple times" do
      assert :ok = DeviceRegistry.flush()
      assert :ok = DeviceRegistry.flush()
    end
  end
end
