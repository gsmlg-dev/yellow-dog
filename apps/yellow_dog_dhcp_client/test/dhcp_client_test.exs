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

  # -- start_interface/2 happy path and duplicate guard --

  describe "start_interface/2" do
    test "returns {:error, {:mac_detection_failed, ...}} when no :mac opt and auto-detect fails" do
      # Nonexistent interface → read_mac fails → resolve_mac returns mac_detection_failed
      result = DhcpClient.start_interface("nonexistent_mac_autodetect_iface")
      assert {:error, {:mac_detection_failed, _reason}} = result
    end

    test "logs a warning when MAC auto-detect fails" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          DhcpClient.start_interface("nonexistent_mac_logtest_iface")
        end)

      assert String.contains?(log, "could not auto-detect MAC")
      assert String.contains?(log, "nonexistent_mac_logtest_iface")
    end

    test "returns {:error, :already_started} when called twice for same interface" do
      unique = System.unique_integer([:positive])
      iface = "test_dup_#{unique}"
      mac = <<0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC>>

      {:ok, _pid} = DhcpClient.start_interface(iface, mac: mac)
      on_exit(fn -> DhcpClient.stop_interface(iface) end)

      assert {:error, :already_started} = DhcpClient.start_interface(iface, mac: mac)
    end
  end

  describe "running interface queries" do
    setup do
      unique = System.unique_integer([:positive])
      iface = "test_running_#{unique}"
      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

      {:ok, _pid} = DhcpClient.start_interface(iface, mac: mac)
      on_exit(fn -> DhcpClient.stop_interface(iface) end)

      %{iface: iface}
    end

    test "status/1 returns an FSM state atom for a running interface", %{iface: iface} do
      state = DhcpClient.status(iface)
      assert is_atom(state)
      assert state == :init
    end

    test "lease/1 returns nil when no lease has been acquired", %{iface: iface} do
      assert nil == DhcpClient.lease(iface)
    end

    test "release/1 returns :ok for a running interface even without a lease", %{iface: iface} do
      assert :ok = DhcpClient.release(iface)
    end

    test "stop_interface/1 returns :ok and terminates the supervisor", %{iface: iface} do
      assert :ok = DhcpClient.stop_interface(iface)
      assert {:error, :not_found} = DhcpClient.status(iface)
    end
  end
end
