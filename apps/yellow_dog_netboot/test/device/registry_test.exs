defmodule YellowDog.Netboot.Device.RegistryTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netboot.Device
  alias YellowDog.Netboot.Device.Persistence
  alias YellowDog.Netboot.Device.Registry
  alias YellowDog.Netboot.ManagedStorage.TestFileOps

  setup do
    root = Path.join(System.tmp_dir!(), "netboot_registry_#{System.unique_integer([:positive])}")
    managed_path = Path.join(root, "managed_devices.json")
    legacy_path = Path.join(root, "devices.toml")
    File.mkdir_p!(root)

    :ets.delete_all_objects(:netboot_devices)

    :sys.replace_state(Registry, fn state ->
      state
      |> Map.put(:managed_path, managed_path)
      |> Map.put(:legacy_path, legacy_path)
      |> Map.put(:persistence_opts, [])
      |> Map.put(:persist_hook, nil)
      |> Map.put(:apply_hook, nil)
      |> Map.put(:broadcast_hook, nil)
    end)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, managed_path: managed_path, legacy_path: legacy_path}
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

  describe "set_rescue_mode/2" do
    test "enables rescue mode on a device" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      assert {:ok, device} = Registry.set_rescue_mode("AA:BB:CC:DD:EE:FF", true)
      assert device.rescue_mode == true
    end

    test "disables rescue mode on a device" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      {:ok, _} = Registry.set_rescue_mode("AA:BB:CC:DD:EE:FF", true)
      assert {:ok, device} = Registry.set_rescue_mode("AA:BB:CC:DD:EE:FF", false)
      assert device.rescue_mode == false
    end

    test "returns error for unknown MAC" do
      assert {:error, :not_found} = Registry.set_rescue_mode("FF:FF:FF:FF:FF:FF", true)
    end
  end

  describe "update_tags/2" do
    test "sets tags on a device" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      assert {:ok, device} = Registry.update_tags("AA:BB:CC:DD:EE:FF", ["gpu", "rack1"])
      assert device.tags == ["gpu", "rack1"]
    end

    test "replaces existing tags" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF", %{tags: ["old"]})
      assert {:ok, device} = Registry.update_tags("AA:BB:CC:DD:EE:FF", ["new1", "new2"])
      assert device.tags == ["new1", "new2"]
    end

    test "returns error for unknown MAC" do
      assert {:error, :not_found} = Registry.update_tags("FF:FF:FF:FF:FF:FF", ["tag"])
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
    test "assigns a previously missing uuid on re-register" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:FF")
      {:ok, updated} = Registry.register("AA:BB:CC:DD:EE:FF", %{uuid: "new-uuid"})
      assert updated.uuid == "new-uuid"
    end

    test "rejects changing an existing immutable uuid" do
      {:ok, original} =
        Registry.register("AA:BB:CC:DD:EE:FF", %{uuid: "device-1", hostname: "server1"})

      assert {:error, :immutable_device_id} =
               Registry.register("AA:BB:CC:DD:EE:FF", %{
                 uuid: "device-2",
                 hostname: "server2"
               })

      assert {:ok, ^original} = Registry.get("AA:BB:CC:DD:EE:FF")
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

  describe "control device ownership" do
    test "creates normal defaults and returns prior/resulting snapshots" do
      assert {:ok, [], [device]} =
               Registry.control_put_device("device-1", "installer", "aa-bb-cc-dd-ee-ff")

      assert device.uuid == "device-1"
      assert device.profile_id == "installer"
      assert device.mac == "AA:BB:CC:DD:EE:FF"
      assert device.state == :discovered
      assert device.hardware_info == %{}
      assert device.install_attempts == 0
      assert [%{state: :discovered}] = device.state_history
      assert {:ok, [^device]} = Registry.control_snapshot()
    end

    test "finds by UUID, atomically re-keys MAC, and preserves every hidden field" do
      first_seen = ~U[2026-07-16 01:02:03Z]
      last_seen = ~U[2026-07-16 04:05:06Z]

      assert {:ok, original} =
               Registry.register("AA:BB:CC:DD:EE:01", %{
                 uuid: "device-1",
                 hostname: "host-1",
                 arch: :aarch64,
                 ip_address: {192, 0, 2, 10},
                 hardware_info: %{"cpu" => "arm"},
                 tags: ["rack-1"]
               })

      original = %{
        original
        | state: :failed,
          first_seen: first_seen,
          last_seen: last_seen,
          install_attempts: 4,
          last_error: "failed",
          state_history: [%{state: :failed, at: last_seen}],
          slot: %{active: :b, pending: :a},
          rescue_mode: true
      }

      replace_snapshot([original])

      assert {:ok, [^original], [updated]} =
               Registry.control_put_device("device-1", "rescue", "AA:BB:CC:DD:EE:02")

      assert updated.uuid == original.uuid
      assert updated.profile_id == "rescue"
      assert updated.mac == "AA:BB:CC:DD:EE:02"

      assert Map.drop(updated, [:mac, :profile_id]) ==
               Map.drop(original, [:mac, :profile_id])

      assert {:error, :not_found} = Registry.get("AA:BB:CC:DD:EE:01")
      assert {:ok, ^updated} = Registry.get("AA:BB:CC:DD:EE:02")
    end

    test "rejects duplicate UUID ownership" do
      assert {:ok, _} =
               Registry.register("AA:BB:CC:DD:EE:01", %{uuid: "device-1"})

      assert {:error, :conflict} =
               Registry.register("AA:BB:CC:DD:EE:02", %{uuid: "device-1"})

      assert Registry.list() |> length() == 1
    end

    test "rejects a control MAC already owned by another UUID" do
      assert {:ok, _prior, _resulting} =
               Registry.control_put_device("device-1", "profile-1", "AA:BB:CC:DD:EE:01")

      assert {:ok, _prior, _resulting} =
               Registry.control_put_device("device-2", "profile-2", "AA:BB:CC:DD:EE:02")

      assert {:error, :conflict} =
               Registry.control_put_device("device-1", "profile-3", "AA:BB:CC:DD:EE:02")

      assert {:ok, device_1} = Registry.get("AA:BB:CC:DD:EE:01")
      assert device_1.profile_id == "profile-1"
    end

    test "deletes by UUID and returns prior/resulting snapshots" do
      assert {:ok, [], [device]} =
               Registry.control_put_device("device-1", "installer", "AA:BB:CC:DD:EE:01")

      assert {:ok, [^device], []} = Registry.control_delete_device("device-1")
      assert {:error, :not_found} = Registry.control_delete_device("device-1")
    end
  end

  describe "managed startup precedence" do
    test "accepts explicit managed and legacy paths in owner start options", %{
      managed_path: managed_path,
      legacy_path: legacy_path
    } do
      managed = Device.new("AA:BB:CC:DD:EE:01", %{uuid: "managed-1"})
      assert :ok = Persistence.save(managed_path, [managed])

      restart_registry(
        managed_devices_path: managed_path,
        legacy_devices_path: legacy_path
      )

      assert {:ok, ^managed} = Registry.get(managed.mac)
      assert %{managed_path: ^managed_path, legacy_path: ^legacy_path} = :sys.get_state(Registry)
    end

    test "loads managed JSON first and only nonconflicting legacy fallback devices", %{
      managed_path: managed_path,
      legacy_path: legacy_path
    } do
      managed =
        %{
          Device.new("AA:BB:CC:DD:EE:01", %{uuid: "managed-1", profile_id: "managed"})
          | hostname: "managed-host"
        }

      assert :ok = Persistence.save(managed_path, [managed])

      File.write!(
        legacy_path,
        """
        [devices.same_mac]
        mac = "AA:BB:CC:DD:EE:01"
        uuid = "legacy-other"
        hostname = "must-not-load"
        state = "discovered"
        install_attempts = 0
        tags = []

        [devices.same_uuid]
        mac = "AA:BB:CC:DD:EE:02"
        uuid = "managed-1"
        hostname = "must-not-load"
        state = "discovered"
        install_attempts = 0
        tags = []

        [devices.fallback]
        mac = "AA:BB:CC:DD:EE:03"
        uuid = "legacy-3"
        hostname = "legacy-fallback"
        state = "installed"
        install_attempts = 1
        tags = ["legacy"]
        """
      )

      restart_registry(managed_path: managed_path, legacy_path: legacy_path)

      assert {:ok, ^managed} = Registry.get("AA:BB:CC:DD:EE:01")
      assert {:error, :not_found} = Registry.get("AA:BB:CC:DD:EE:02")
      assert {:ok, fallback} = Registry.get("AA:BB:CC:DD:EE:03")
      assert fallback.uuid == "legacy-3"
      assert fallback.hostname == "legacy-fallback"
    end

    test "a complete committed snapshot survives a registry restart", %{
      managed_path: managed_path,
      legacy_path: legacy_path
    } do
      assert {:ok, device} =
               Registry.register("AA:BB:CC:DD:EE:01", %{
                 uuid: "device-1",
                 hostname: "host-1",
                 arch: :x86_64,
                 ip_address: {192, 0, 2, 10},
                 hardware_info: %{"serial" => "abc"},
                 tags: ["rack-1"]
               })

      assert {:ok, device} = Registry.update_state(device.mac, :booting)
      assert {:ok, device} = Registry.set_rescue_mode(device.mac, true)
      assert {:ok, device} = Registry.assign_profile(device.mac, "installer")

      restart_registry(managed_path: managed_path, legacy_path: legacy_path)

      assert {:ok, ^device} = Registry.get("AA:BB:CC:DD:EE:01")
    end
  end

  describe "serialized durable mutations" do
    test "persists the complete candidate before ETS activation and broadcast", %{
      managed_path: managed_path
    } do
      parent = self()

      set_hooks(
        apply_hook: fn candidate ->
          send(parent, {:apply, Persistence.load(managed_path), candidate, Registry.list()})
          :ok
        end,
        broadcast_hook: fn event ->
          send(parent, {:broadcast, event, Persistence.load(managed_path), Registry.list()})
          :ok
        end
      )

      assert {:ok, device} =
               Registry.register("AA:BB:CC:DD:EE:01", %{
                 uuid: "device-1",
                 hardware_info: %{"cpu" => "x86"},
                 tags: ["rack-1"]
               })

      assert_receive {:apply, {:ok, [^device]}, [^device], [^device]}
      assert_receive {:broadcast, {:device_registered, ^device}, {:ok, [^device]}, [^device]}
    end

    test "every public mutation commits the complete resulting snapshot", %{
      managed_path: managed_path
    } do
      assert {:ok, device} =
               Registry.register("AA:BB:CC:DD:EE:01", %{uuid: "device-1"})

      assert_persisted(managed_path)

      assert {:ok, device} = Registry.update_state(device.mac, :booting)
      assert_persisted(managed_path)

      assert {:ok, device} = Registry.update_state(device.mac, :installing)
      assert_persisted(managed_path)

      assert {:ok, device} = Registry.update_state(device.mac, :installed)
      assert_persisted(managed_path)

      assert {:ok, device} = Registry.request_reinstall(device.mac)
      assert_persisted(managed_path)

      assert {:ok, device} = Registry.assign_profile(device.mac, "installer")
      assert_persisted(managed_path)

      assert {:ok, device} = Registry.set_rescue_mode(device.mac, true)
      assert_persisted(managed_path)

      assert {:ok, _device} = Registry.update_tags(device.mac, ["rack-2"])
      assert_persisted(managed_path)

      assert {:ok, _prior, _resulting} =
               Registry.control_put_device("device-1", "rescue", "AA:BB:CC:DD:EE:02")

      assert_persisted(managed_path)

      assert :ok = Registry.delete("AA:BB:CC:DD:EE:02")
      assert {:ok, []} = Persistence.load(managed_path)
      assert Registry.list() == []
    end

    for phase <- [:write, :sync, :close, :rename] do
      test "#{phase} failure leaves sidecar and ETS unchanged and does not broadcast", %{
        managed_path: managed_path
      } do
        assert {:ok, prior} =
                 Registry.register("AA:BB:CC:DD:EE:01", %{
                   uuid: "device-1",
                   profile_id: "prior"
                 })

        prior_bytes = File.read!(managed_path)
        parent = self()

        set_hooks(
          persistence_opts: [
            file_ops: {TestFileOps, %{fail: unquote(phase)}}
          ],
          broadcast_hook: fn event ->
            send(parent, {:unexpected_broadcast, event})
            :ok
          end
        )

        assert {:error, :persistence_failed} =
                 Registry.assign_profile(prior.mac, "candidate")

        assert File.read!(managed_path) == prior_bytes
        assert {:ok, ^prior} = Registry.get(prior.mac)
        refute_receive {:unexpected_broadcast, _event}
      end
    end

    test "apply failure restores the sidecar first and ETS second without broadcasting", %{
      managed_path: managed_path
    } do
      assert {:ok, prior} =
               Registry.register("AA:BB:CC:DD:EE:01", %{
                 uuid: "device-1",
                 profile_id: "prior"
               })

      parent = self()
      {:ok, apply_results} = Agent.start_link(fn -> [:error, :ok] end)

      set_hooks(
        apply_hook: fn candidate ->
          result = Agent.get_and_update(apply_results, fn [result | rest] -> {result, rest} end)

          send(
            parent,
            {:apply_attempt, result, candidate, Persistence.load(managed_path), Registry.list()}
          )

          result
        end,
        broadcast_hook: fn event ->
          send(parent, {:unexpected_broadcast, event})
          :ok
        end
      )

      assert {:error, :apply_failed} = Registry.assign_profile(prior.mac, "candidate")

      assert_receive {:apply_attempt, :error, [candidate], {:ok, [persisted]}, [runtime]}
      assert persisted == candidate
      assert runtime == candidate
      assert candidate.profile_id == "candidate"
      assert_receive {:apply_attempt, :ok, [^prior], {:ok, [^prior]}, [^prior]}
      assert {:ok, ^prior} = Registry.get(prior.mac)
      assert {:ok, [^prior]} = Persistence.load(managed_path)
      refute_receive {:unexpected_broadcast, _event}
    end

    test "reports rollback failure and keeps the candidate active when sidecar restore fails", %{
      managed_path: managed_path
    } do
      assert {:ok, prior} =
               Registry.register("AA:BB:CC:DD:EE:01", %{
                 uuid: "device-1",
                 profile_id: "prior"
               })

      {:ok, saves} = Agent.start_link(fn -> [:ok, :error] end)

      set_hooks(
        apply_hook: fn _candidate -> :error end,
        persist_hook: fn path, devices, opts ->
          case Agent.get_and_update(saves, fn [result | rest] -> {result, rest} end) do
            :ok -> Persistence.save(path, devices, opts)
            :error -> {:error, :injected}
          end
        end
      )

      assert {:error, :rollback_failed} = Registry.assign_profile(prior.mac, "candidate")
      assert {:ok, [candidate]} = Registry.control_snapshot()
      assert candidate.profile_id == "candidate"
      assert {:ok, [^candidate]} = Persistence.load(managed_path)
    end

    test "reports rollback failure distinctly when restoring ETS fails", %{
      managed_path: managed_path
    } do
      assert {:ok, prior} =
               Registry.register("AA:BB:CC:DD:EE:01", %{
                 uuid: "device-1",
                 profile_id: "prior"
               })

      {:ok, applies} = Agent.start_link(fn -> [:error, :error] end)

      set_hooks(
        apply_hook: fn _candidate ->
          Agent.get_and_update(applies, fn [result | rest] -> {result, rest} end)
        end
      )

      assert {:error, :rollback_failed} = Registry.assign_profile(prior.mac, "candidate")
      assert {:ok, ^prior} = Registry.get(prior.mac)
      assert {:ok, [^prior]} = Persistence.load(managed_path)
    end
  end

  test "catch-all handle_info ignores unknown messages" do
    pid = Process.whereis(Registry)
    send(pid, :some_unknown_message)
    Process.sleep(10)
    assert Process.alive?(pid)
  end

  defp set_hooks(overrides) do
    :sys.replace_state(Registry, fn state ->
      Enum.reduce(overrides, state, fn {key, value}, state -> Map.put(state, key, value) end)
    end)
  end

  defp replace_snapshot(devices) do
    :ets.delete_all_objects(:netboot_devices)
    true = :ets.insert(:netboot_devices, Enum.map(devices, &{&1.mac, &1}))
  end

  defp assert_persisted(managed_path) do
    assert {:ok, persisted} = Persistence.load(managed_path)
    assert persisted == Registry.list() |> Enum.sort_by(& &1.mac)
  end

  defp restart_registry(opts) do
    supervisor = YellowDog.Netboot.Supervisor

    assert :ok = Supervisor.terminate_child(supervisor, Registry)
    assert :ok = Supervisor.delete_child(supervisor, Registry)
    assert {:ok, _pid} = Supervisor.start_child(supervisor, {Registry, opts})
  end
end
