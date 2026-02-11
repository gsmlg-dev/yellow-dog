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
end
