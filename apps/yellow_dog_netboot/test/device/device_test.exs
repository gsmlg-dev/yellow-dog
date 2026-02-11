defmodule YellowDog.Netboot.DeviceTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.Device

  describe "new/2" do
    test "creates device with normalized MAC" do
      device = Device.new("aa:bb:cc:dd:ee:ff")
      assert device.mac == "AA:BB:CC:DD:EE:FF"
      assert device.state == :discovered
      assert device.install_attempts == 0
      assert device.tags == []
    end

    test "accepts optional attributes" do
      device =
        Device.new("AA:BB:CC:DD:EE:FF", %{hostname: "server1", arch: :x86_64, tags: ["rack1"]})

      assert device.hostname == "server1"
      assert device.arch == :x86_64
      assert device.tags == ["rack1"]
    end

    test "sets first_seen and last_seen timestamps" do
      device = Device.new("AA:BB:CC:DD:EE:FF")
      assert %DateTime{} = device.first_seen
      assert %DateTime{} = device.last_seen
    end
  end

  describe "transition/3" do
    test "discovered → booting" do
      device = Device.new("AA:BB:CC:DD:EE:FF")
      assert {:ok, updated} = Device.transition(device, :booting)
      assert updated.state == :booting
      assert updated.install_attempts == 1
    end

    test "booting → installing" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :booting}
      assert {:ok, updated} = Device.transition(device, :installing)
      assert updated.state == :installing
    end

    test "installing → installed" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :installing}
      assert {:ok, updated} = Device.transition(device, :installed)
      assert updated.state == :installed
      assert updated.last_error == nil
    end

    test "booting → failed with error message" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :booting}
      assert {:ok, updated} = Device.transition(device, :failed, %{error: "timeout"})
      assert updated.state == :failed
      assert updated.last_error == "timeout"
    end

    test "installing → failed" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :installing}
      assert {:ok, updated} = Device.transition(device, :failed, %{error: "disk error"})
      assert updated.state == :failed
      assert updated.last_error == "disk error"
    end

    test "failed → discovered (reset)" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :failed}
      assert {:ok, updated} = Device.transition(device, :discovered)
      assert updated.state == :discovered
    end

    test "failed → booting (retry)" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :failed, install_attempts: 2}
      assert {:ok, updated} = Device.transition(device, :booting)
      assert updated.state == :booting
      assert updated.install_attempts == 3
    end

    test "installed → reinstall_requested" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :installed}
      assert {:ok, updated} = Device.transition(device, :reinstall_requested)
      assert updated.state == :reinstall_requested
    end

    test "reinstall_requested → booting" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :reinstall_requested}
      assert {:ok, updated} = Device.transition(device, :booting)
      assert updated.state == :booting
    end

    test "rejects invalid transition discovered → installed" do
      device = Device.new("AA:BB:CC:DD:EE:FF")
      assert {:error, :invalid_transition} = Device.transition(device, :installed)
    end

    test "rejects invalid transition installed → booting" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :installed}
      assert {:error, :invalid_transition} = Device.transition(device, :booting)
    end
  end

  describe "state_history" do
    test "new device has initial discovered entry" do
      device = Device.new("AA:BB:CC:DD:EE:FF")
      assert [%{state: :discovered, at: %DateTime{}}] = device.state_history
    end

    test "transition appends to history" do
      device = Device.new("AA:BB:CC:DD:EE:FF")
      {:ok, device} = Device.transition(device, :booting)
      {:ok, device} = Device.transition(device, :installing)
      {:ok, device} = Device.transition(device, :installed)

      # History is prepended (newest first)
      assert [
               %{state: :installed},
               %{state: :installing},
               %{state: :booting},
               %{state: :discovered}
             ] = device.state_history
    end

    test "failed transition does not modify history" do
      device = Device.new("AA:BB:CC:DD:EE:FF")
      assert {:error, :invalid_transition} = Device.transition(device, :installed)
      assert length(device.state_history) == 1
    end
  end

  describe "normalize_mac/1" do
    test "normalizes lowercase to uppercase" do
      assert "AA:BB:CC:DD:EE:FF" = Device.normalize_mac("aa:bb:cc:dd:ee:ff")
    end

    test "normalizes dash-separated" do
      assert "AA:BB:CC:DD:EE:FF" = Device.normalize_mac("AA-BB-CC-DD-EE-FF")
    end

    test "normalizes without separators" do
      assert "AA:BB:CC:DD:EE:FF" = Device.normalize_mac("AABBCCDDEEFF")
    end
  end

  describe "valid_transitions/1" do
    test "discovered can go to booting" do
      device = Device.new("AA:BB:CC:DD:EE:FF")
      assert [:booting] = Device.valid_transitions(device)
    end

    test "failed can go to discovered or booting" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :failed}
      transitions = Device.valid_transitions(device)
      assert :discovered in transitions
      assert :booting in transitions
    end
  end

  test "valid_states/0 returns all states" do
    states = Device.valid_states()
    assert :discovered in states
    assert :installed in states
    assert length(states) == 6
  end

  test "valid_arches/0 returns all architectures" do
    arches = Device.valid_arches()
    assert :x86_64 in arches
    assert :aarch64 in arches
    assert :bios_x86 in arches
  end

  describe "new/2 arch validation" do
    test "accepts valid arch as string" do
      device = Device.new("AA:BB:CC:DD:EE:FF", %{arch: "x86_64"})
      assert device.arch == :x86_64
    end

    test "accepts valid arch as atom" do
      device = Device.new("AA:BB:CC:DD:EE:FF", %{arch: :aarch64})
      assert device.arch == :aarch64
    end

    test "rejects invalid arch string" do
      device = Device.new("AA:BB:CC:DD:EE:FF", %{arch: "mips"})
      assert device.arch == nil
    end

    test "rejects non-existent atom arch string" do
      device = Device.new("AA:BB:CC:DD:EE:FF", %{arch: "not_a_real_arch_at_all_12345"})
      assert device.arch == nil
    end

    test "rejects invalid arch type (integer)" do
      device = Device.new("AA:BB:CC:DD:EE:FF", %{arch: 42})
      assert device.arch == nil
    end

    test "nil arch stays nil" do
      device = Device.new("AA:BB:CC:DD:EE:FF", %{arch: nil})
      assert device.arch == nil
    end
  end

  describe "new/2 optional fields" do
    test "sets uuid" do
      device = Device.new("AA:BB:CC:DD:EE:FF", %{uuid: "abc-123"})
      assert device.uuid == "abc-123"
    end

    test "sets profile_id" do
      device = Device.new("AA:BB:CC:DD:EE:FF", %{profile_id: "nixos-minimal"})
      assert device.profile_id == "nixos-minimal"
    end

    test "sets ip_address" do
      device = Device.new("AA:BB:CC:DD:EE:FF", %{ip_address: {192, 168, 1, 100}})
      assert device.ip_address == {192, 168, 1, 100}
    end

    test "default slot is %{active: :a, pending: nil}" do
      device = Device.new("AA:BB:CC:DD:EE:FF")
      assert device.slot == %{active: :a, pending: nil}
    end

    test "default hardware_info is empty map" do
      device = Device.new("AA:BB:CC:DD:EE:FF")
      assert device.hardware_info == %{}
    end
  end

  describe "transition/3 side effects" do
    test "installed clears last_error" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :installing, last_error: "previous"}
      assert {:ok, updated} = Device.transition(device, :installed)
      assert updated.last_error == nil
    end

    test "generic transition (no special side effects)" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :installed}
      assert {:ok, updated} = Device.transition(device, :reinstall_requested)
      # No side effects besides state change
      assert updated.state == :reinstall_requested
    end

    test "transition updates last_seen" do
      device = Device.new("AA:BB:CC:DD:EE:FF")
      old_last_seen = device.last_seen
      Process.sleep(10)
      {:ok, updated} = Device.transition(device, :booting)
      assert DateTime.compare(updated.last_seen, old_last_seen) in [:gt, :eq]
    end
  end

  describe "normalize_mac/1 edge cases" do
    test "normalizes dot-separated MAC" do
      assert "AA:BB:CC:DD:EE:FF" = Device.normalize_mac("AA.BB.CC.DD.EE.FF")
    end

    test "normalizes mixed case with dashes" do
      assert "AA:BB:CC:DD:EE:FF" = Device.normalize_mac("aA-bB-cC-dD-eE-fF")
    end
  end
end
