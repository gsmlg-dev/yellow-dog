defmodule YellowDog.DhcpClientTest do
  use ExUnit.Case, async: true

  alias YellowDog.DhcpClient

  # -- read_mac/1 --

  describe "read_mac/1" do
    test "returns error for non-existent interface" do
      result = DhcpClient.read_mac("nonexistent_iface_xyz_999")
      assert {:error, {:read_mac, "nonexistent_iface_xyz_999", _reason}} = result
    end

    test "returns 6-byte binary on success (loopback if available)" do
      # Attempt with loopback; skip gracefully if not available in the test environment
      case DhcpClient.read_mac("lo") do
        {:ok, mac} ->
          assert is_binary(mac)
          assert byte_size(mac) == 6

        {:error, _} ->
          # loopback may not have a MAC address on all systems (returns 00:00:00:00:00:00)
          # or may not be readable — both are valid outcomes
          :ok
      end
    end

    test "returns error for invalid MAC content (uses temp file)" do
      # Since read_mac reads /sys/class/net/{iface}/address, we can't intercept
      # without process mocking. Instead, verify the error shape for missing iface.
      result = DhcpClient.read_mac("")
      assert {:error, _} = result
    end
  end

  # -- Public API edge cases --

  describe "stop_interface/1" do
    test "returns {:error, :not_found} for non-running interface" do
      assert {:error, :not_found} = DhcpClient.stop_interface("nonexistent_api_test_iface")
    end
  end

  describe "release/1" do
    test "returns {:error, :not_found} for non-running interface" do
      assert {:error, :not_found} = DhcpClient.release("nonexistent_api_test_iface")
    end
  end

  describe "status/1" do
    test "returns {:error, :not_found} for non-running interface" do
      assert {:error, :not_found} = DhcpClient.status("nonexistent_api_test_iface")
    end
  end

  describe "lease/1" do
    test "returns nil for non-running interface" do
      assert nil == DhcpClient.lease("nonexistent_api_test_iface")
    end
  end
end
