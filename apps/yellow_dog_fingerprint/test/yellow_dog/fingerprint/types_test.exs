defmodule YellowDog.Fingerprint.TypesTest do
  use ExUnit.Case, async: true

  alias YellowDog.Fingerprint.Types.{Device, DeviceProfile, Fingerprint}

  # ── Fingerprint.compute_id/3 ─────────────────────────────────────

  describe "Fingerprint.compute_id/3" do
    test "computes deterministic SHA-256 hash" do
      id1 = Fingerprint.compute_id(:dhcpv4, [1, 3, 6, 15], "MSFT 5.0")
      id2 = Fingerprint.compute_id(:dhcpv4, [1, 3, 6, 15], "MSFT 5.0")
      assert id1 == id2
      assert byte_size(id1) == 64
    end

    test "different parameters produce different hashes" do
      id1 = Fingerprint.compute_id(:dhcpv4, [1, 3, 6, 15], "MSFT 5.0")
      id2 = Fingerprint.compute_id(:dhcpv4, [1, 3, 6], "MSFT 5.0")
      assert id1 != id2
    end

    test "different vendor classes produce different hashes" do
      id1 = Fingerprint.compute_id(:dhcpv4, [1, 3, 6], "MSFT 5.0")
      id2 = Fingerprint.compute_id(:dhcpv4, [1, 3, 6], "android-dhcp-14")
      assert id1 != id2
    end

    test "nil vendor class is treated as empty string" do
      id1 = Fingerprint.compute_id(:dhcpv4, [1, 3, 6], nil)
      id2 = Fingerprint.compute_id(:dhcpv4, [1, 3, 6], nil)
      assert id1 == id2
    end

    test "protocol affects hash" do
      id_v4 = Fingerprint.compute_id(:dhcpv4, [1, 3, 6], nil)
      id_v6 = Fingerprint.compute_id(:dhcpv6, [1, 3, 6], nil)
      assert id_v4 != id_v6
    end

    test "empty parameter list produces valid hash" do
      id = Fingerprint.compute_id(:dhcpv4, [], nil)
      assert byte_size(id) == 64
    end

    test "returns lowercase hex string" do
      id = Fingerprint.compute_id(:dhcpv4, [1, 2, 3], "test")
      assert id =~ ~r/^[0-9a-f]{64}$/
    end

    test "parameter order matters" do
      id1 = Fingerprint.compute_id(:dhcpv4, [1, 3, 6], nil)
      id2 = Fingerprint.compute_id(:dhcpv4, [6, 3, 1], nil)
      assert id1 != id2
    end
  end

  # ── Fingerprint struct defaults ──────────────────────────────────

  describe "Fingerprint struct" do
    test "default values" do
      fp = %Fingerprint{}
      assert fp.parameter_list == []
      assert fp.hit_count == 0
      assert fp.protocol == nil
      assert fp.vendor_class == nil
    end

    test "all fields can be set" do
      now = DateTime.utc_now()

      fp = %Fingerprint{
        id: "abc",
        protocol: :dhcpv4,
        parameter_list: [1, 3, 6, 15],
        vendor_class: "MSFT 5.0",
        hostname_pattern: "DESKTOP-*",
        first_seen: now,
        last_seen: now,
        hit_count: 42
      }

      assert fp.id == "abc"
      assert fp.protocol == :dhcpv4
      assert fp.parameter_list == [1, 3, 6, 15]
      assert fp.vendor_class == "MSFT 5.0"
      assert fp.hostname_pattern == "DESKTOP-*"
      assert fp.hit_count == 42
    end
  end

  # ── DeviceProfile.parse_device_type/1 ────────────────────────────

  describe "DeviceProfile.parse_device_type/1" do
    test "parses valid string device types" do
      assert DeviceProfile.parse_device_type("computer") == :computer
      assert DeviceProfile.parse_device_type("phone") == :phone
      assert DeviceProfile.parse_device_type("iot") == :iot
    end

    test "parses valid atom device types" do
      assert DeviceProfile.parse_device_type(:printer) == :printer
      assert DeviceProfile.parse_device_type(:camera) == :camera
    end

    test "returns :unknown for invalid types" do
      assert DeviceProfile.parse_device_type("invalid") == :unknown
      assert DeviceProfile.parse_device_type(42) == :unknown
    end

    test "parses all 14 valid device type strings" do
      valid_types = ~w(computer phone tablet printer voip_phone camera tv
                       game_console iot network_equipment server
                       virtual_machine container unknown)

      for type <- valid_types do
        result = DeviceProfile.parse_device_type(type)
        assert is_atom(result), "Failed to parse: #{type}"
        assert result == String.to_existing_atom(type)
      end
    end

    test "parses all valid atom types" do
      valid_atoms =
        ~w(computer phone tablet printer voip_phone camera tv
           game_console iot network_equipment server
           virtual_machine container unknown)a

      for type <- valid_atoms do
        assert DeviceProfile.parse_device_type(type) == type
      end
    end

    test "returns :unknown for nil" do
      assert DeviceProfile.parse_device_type(nil) == :unknown
    end

    test "returns :unknown for list" do
      assert DeviceProfile.parse_device_type([]) == :unknown
    end
  end

  # ── DeviceProfile struct defaults ────────────────────────────────

  describe "DeviceProfile struct" do
    test "default values" do
      dp = %DeviceProfile{}
      assert dp.device_type == :unknown
      assert dp.confidence == 0
      assert dp.source == :local
      assert dp.id == nil
      assert dp.name == nil
    end

    test "all fields can be set" do
      dp = %DeviceProfile{
        id: "profile-1",
        name: "Windows 11 Desktop",
        os_family: "Windows",
        os_version: "11",
        device_type: :computer,
        vendor: "Dell",
        confidence: 95,
        source: :fingerbank
      }

      assert dp.id == "profile-1"
      assert dp.name == "Windows 11 Desktop"
      assert dp.os_family == "Windows"
      assert dp.os_version == "11"
      assert dp.device_type == :computer
      assert dp.vendor == "Dell"
      assert dp.confidence == 95
      assert dp.source == :fingerbank
    end

    test "source can be :user_override" do
      dp = %DeviceProfile{source: :user_override}
      assert dp.source == :user_override
    end
  end

  # ── Device struct ────────────────────────────────────────────────

  describe "Device struct" do
    test "default values" do
      device = %Device{}
      assert device.ipv4_addresses == []
      assert device.ipv6_addresses == []
      assert device.profile_confidence == 0
      assert device.observation_count == 0
      assert device.metadata == %{}
      assert device.mac == nil
    end

    test "all fields can be set" do
      now = DateTime.utc_now()

      device = %Device{
        id: "dev-1",
        mac: "AA:BB:CC:DD:EE:FF",
        oui_vendor: "Dell Inc.",
        duid: <<0, 1, 0, 1>>,
        hostname: "server1",
        fingerprint_v4_id: "fp-v4-1",
        fingerprint_v6_id: "fp-v6-1",
        profile_id: "profile-1",
        first_seen: now,
        last_seen: now,
        ipv4_addresses: ["192.168.1.100"],
        ipv6_addresses: ["fe80::1"],
        profile_confidence: 95,
        observation_count: 10,
        metadata: %{"location" => "rack-3"}
      }

      assert device.id == "dev-1"
      assert device.mac == "AA:BB:CC:DD:EE:FF"
      assert device.oui_vendor == "Dell Inc."
      assert device.duid == <<0, 1, 0, 1>>
      assert device.hostname == "server1"
      assert device.fingerprint_v4_id == "fp-v4-1"
      assert device.fingerprint_v6_id == "fp-v6-1"
      assert device.profile_id == "profile-1"
      assert device.ipv4_addresses == ["192.168.1.100"]
      assert device.ipv6_addresses == ["fe80::1"]
      assert device.profile_confidence == 95
      assert device.observation_count == 10
      assert device.metadata == %{"location" => "rack-3"}
    end

    test "multiple IP addresses" do
      device = %Device{
        mac: "AA:BB:CC:DD:EE:FF",
        ipv4_addresses: ["192.168.1.100", "10.0.0.5"],
        ipv6_addresses: ["fe80::1", "2001:db8::1", "::1"]
      }

      assert length(device.ipv4_addresses) == 2
      assert length(device.ipv6_addresses) == 3
    end

    test "duid can be binary" do
      device = %Device{duid: :crypto.strong_rand_bytes(14)}
      assert is_binary(device.duid)
    end

    test "metadata can hold arbitrary data" do
      device = %Device{
        metadata: %{
          "vendor_class" => "MSFT 5.0",
          "dhcp_options" => [1, 3, 6, 15],
          "last_port" => 68
        }
      }

      assert device.metadata["vendor_class"] == "MSFT 5.0"
      assert device.metadata["dhcp_options"] == [1, 3, 6, 15]
    end
  end
end
