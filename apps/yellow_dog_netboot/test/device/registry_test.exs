defmodule YellowDog.Netboot.Device.RegistryTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netboot.Device.Registry

  setup do
    # The Registry is already started by Application.
    # Clear ETS table between tests.
    :ets.delete_all_objects(YellowDog.Netboot.Device.Registry)
    :ok
  end

  describe "register/2" do
    test "registers a new device" do
      assert {:ok, device} = Registry.register("AA:BB:CC:DD:EE:FF")
      assert device.mac == "AA:BB:CC:DD:EE:FF"
      assert device.state == :discovered
    end

    test "registers with attributes" do
      assert {:ok, device} =
               Registry.register("AA:BB:CC:DD:EE:FF", %{hostname: "server1", arch: :x86_64})

      assert device.hostname == "server1"
      assert device.arch == :x86_64
    end

    test "updates existing device on re-register" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      {:ok, updated} = Registry.register("AA:BB:CC:DD:EE:FF", %{hostname: "server2"})
      assert updated.hostname == "server2"
    end
  end

  describe "get/1" do
    test "returns device by MAC" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      assert {:ok, device} = Registry.get("AA:BB:CC:DD:EE:FF")
      assert device.mac == "AA:BB:CC:DD:EE:FF"
    end

    test "returns error for unknown MAC" do
      assert {:error, :not_found} = Registry.get("FF:FF:FF:FF:FF:FF")
    end

    test "normalizes MAC for lookup" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      assert {:ok, _} = Registry.get("aa:bb:cc:dd:ee:ff")
    end
  end

  describe "update_state/3" do
    test "transitions device state" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      assert {:ok, device} = Registry.update_state("AA:BB:CC:DD:EE:FF", :booting)
      assert device.state == :booting
    end

    test "rejects invalid transition" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")

      assert {:error, :invalid_transition} =
               Registry.update_state("AA:BB:CC:DD:EE:FF", :installed)
    end

    test "returns error for unknown MAC" do
      assert {:error, :not_found} = Registry.update_state("FF:FF:FF:FF:FF:FF", :booting)
    end
  end

  describe "assign_profile/2" do
    test "assigns a profile to a device" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      assert {:ok, device} = Registry.assign_profile("AA:BB:CC:DD:EE:FF", "nixos-minimal")
      assert device.profile_id == "nixos-minimal"
    end

    test "returns error for unknown MAC" do
      assert {:error, :not_found} = Registry.assign_profile("FF:FF:FF:FF:FF:FF", "nixos-minimal")
    end
  end

  describe "delete/1" do
    test "removes a device" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      assert :ok = Registry.delete("AA:BB:CC:DD:EE:FF")
      assert {:error, :not_found} = Registry.get("AA:BB:CC:DD:EE:FF")
    end
  end

  describe "list/1" do
    test "lists all devices" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01")
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:02")
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:03")
      assert length(Registry.list()) == 3
    end

    test "filters by state" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01")
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:02")
      Registry.update_state("AA:BB:CC:DD:EE:01", :booting)

      discovered = Registry.list(state: :discovered)
      assert length(discovered) == 1

      booting = Registry.list(state: :booting)
      assert length(booting) == 1
    end

    test "filters by profile_id" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01")
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:02")
      Registry.assign_profile("AA:BB:CC:DD:EE:01", "nixos-minimal")

      result = Registry.list(profile_id: "nixos-minimal")
      assert length(result) == 1
      assert hd(result).mac == "AA:BB:CC:DD:EE:01"
    end
  end

  describe "count_by_state/0" do
    test "returns state frequencies" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01")
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:02")
      Registry.update_state("AA:BB:CC:DD:EE:01", :booting)

      counts = Registry.count_by_state()
      assert counts[:discovered] == 1
      assert counts[:booting] == 1
    end

    test "returns empty map when no devices" do
      assert Registry.count_by_state() == %{}
    end
  end

  describe "request_reinstall/1" do
    test "transitions installed device to reinstall_requested" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      Registry.update_state("AA:BB:CC:DD:EE:FF", :booting)
      Registry.update_state("AA:BB:CC:DD:EE:FF", :installing)
      Registry.update_state("AA:BB:CC:DD:EE:FF", :installed)

      assert {:ok, device} = Registry.request_reinstall("AA:BB:CC:DD:EE:FF")
      assert device.state == :reinstall_requested
    end

    test "returns error for unknown MAC" do
      assert {:error, :not_found} = Registry.request_reinstall("FF:FF:FF:FF:FF:FF")
    end
  end

  describe "list/1 filters" do
    test "filters by arch" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01", %{arch: :x86_64})
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:02", %{arch: :aarch64})

      result = Registry.list(arch: :x86_64)
      assert length(result) == 1
      assert hd(result).arch == :x86_64
    end

    test "filters by tag" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01", %{tags: ["gpu", "rack1"]})
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:02", %{tags: ["rack2"]})

      result = Registry.list(tag: "gpu")
      assert length(result) == 1
      assert hd(result).mac == "AA:BB:CC:DD:EE:01"
    end

    test "ignores unknown filter keys" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01")
      result = Registry.list(unknown_filter: "value")
      assert length(result) == 1
    end

    test "combines multiple filters" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01", %{arch: :x86_64})
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:02", %{arch: :x86_64})
      Registry.assign_profile("AA:BB:CC:DD:EE:01", "nixos")

      result = Registry.list(arch: :x86_64, profile_id: "nixos")
      assert length(result) == 1
      assert hd(result).mac == "AA:BB:CC:DD:EE:01"
    end
  end

  describe "register/2 re-registration updates" do
    test "updates uuid on re-register" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      {:ok, updated} = Registry.register("AA:BB:CC:DD:EE:FF", %{uuid: "new-uuid"})
      assert updated.uuid == "new-uuid"
    end

    test "updates ip_address on re-register" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      {:ok, updated} = Registry.register("AA:BB:CC:DD:EE:FF", %{ip_address: {10, 0, 0, 1}})
      assert updated.ip_address == {10, 0, 0, 1}
    end

    test "nil attribute does not overwrite existing value" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF", %{hostname: "server1"})
      {:ok, updated} = Registry.register("AA:BB:CC:DD:EE:FF", %{hostname: nil})
      assert updated.hostname == "server1"
    end
  end

  describe "persistence integration" do
    @tag :tmp_dir
    test "mutations schedule a persist timer", %{tmp_dir: tmp_dir} do
      persist_path = Path.join(tmp_dir, "devices.toml")

      # Swap persist path to a writable temp location
      :sys.replace_state(Registry, fn state ->
        if state.persist_timer, do: Process.cancel_timer(state.persist_timer)
        %{state | persist_path: persist_path, persist_timer: nil}
      end)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01")

      # After a mutation, a persist timer should be scheduled
      gen_state = :sys.get_state(Registry)
      assert gen_state.persist_timer != nil
      assert is_reference(gen_state.persist_timer)
    end

    @tag :tmp_dir
    test "persist message writes devices to disk", %{tmp_dir: tmp_dir} do
      persist_path = Path.join(tmp_dir, "devices.toml")

      :sys.replace_state(Registry, fn state ->
        if state.persist_timer, do: Process.cancel_timer(state.persist_timer)
        %{state | persist_path: persist_path, persist_timer: nil}
      end)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01", %{hostname: "srv1"})
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:02", %{hostname: "srv2"})

      # Force immediate persist by sending the message
      send(Process.whereis(Registry), :persist)
      # Give GenServer time to handle the message
      Process.sleep(50)

      assert File.exists?(persist_path)
      content = File.read!(persist_path)
      assert String.contains?(content, "AA:BB:CC:DD:EE:01")
      assert String.contains?(content, "AA:BB:CC:DD:EE:02")
      assert String.contains?(content, "srv1")
    end

    @tag :tmp_dir
    test "persist clears the timer reference", %{tmp_dir: tmp_dir} do
      persist_path = Path.join(tmp_dir, "devices.toml")

      :sys.replace_state(Registry, fn state ->
        if state.persist_timer, do: Process.cancel_timer(state.persist_timer)
        %{state | persist_path: persist_path, persist_timer: nil}
      end)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01")

      # Timer should be set
      assert :sys.get_state(Registry).persist_timer != nil

      # Force persist
      send(Process.whereis(Registry), :persist)
      Process.sleep(50)

      # Timer should be cleared after persist
      assert :sys.get_state(Registry).persist_timer == nil
    end

    @tag :tmp_dir
    test "delete also triggers persist", %{tmp_dir: tmp_dir} do
      persist_path = Path.join(tmp_dir, "devices.toml")

      :sys.replace_state(Registry, fn state ->
        if state.persist_timer, do: Process.cancel_timer(state.persist_timer)
        %{state | persist_path: persist_path, persist_timer: nil}
      end)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01")

      # Cancel the timer from register, clear it
      :sys.replace_state(Registry, fn state ->
        if state.persist_timer, do: Process.cancel_timer(state.persist_timer)
        %{state | persist_timer: nil}
      end)

      :ok = Registry.delete("AA:BB:CC:DD:EE:01")

      # Delete should schedule a new timer
      assert :sys.get_state(Registry).persist_timer != nil
    end

    @tag :tmp_dir
    test "assign_profile triggers persist", %{tmp_dir: tmp_dir} do
      persist_path = Path.join(tmp_dir, "devices.toml")

      :sys.replace_state(Registry, fn state ->
        if state.persist_timer, do: Process.cancel_timer(state.persist_timer)
        %{state | persist_path: persist_path, persist_timer: nil}
      end)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01")

      :sys.replace_state(Registry, fn state ->
        if state.persist_timer, do: Process.cancel_timer(state.persist_timer)
        %{state | persist_timer: nil}
      end)

      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:01", "nixos")
      assert :sys.get_state(Registry).persist_timer != nil
    end

    @tag :tmp_dir
    test "persisted data survives forced write and reload", %{tmp_dir: tmp_dir} do
      persist_path = Path.join(tmp_dir, "devices.toml")

      :sys.replace_state(Registry, fn state ->
        if state.persist_timer, do: Process.cancel_timer(state.persist_timer)
        %{state | persist_path: persist_path, persist_timer: nil}
      end)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01", %{hostname: "host1", arch: :x86_64})
      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:01", "nixos-minimal")

      # Force persist
      send(Process.whereis(Registry), :persist)
      Process.sleep(50)

      # Verify persisted data can be loaded by Persistence module
      {:ok, devices} = YellowDog.Netboot.Device.Persistence.load(persist_path)
      assert length(devices) == 1
      device = hd(devices)
      assert device.mac == "AA:BB:CC:DD:EE:01"
      assert device.hostname == "host1"
      assert device.arch == :x86_64
      assert device.profile_id == "nixos-minimal"
    end
  end
end
