defmodule YellowDog.Fingerprint.TypesTest do
  use ExUnit.Case, async: true

  alias YellowDog.Fingerprint.Types.{DeviceProfile, Fingerprint}

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
  end

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
  end
end
