defmodule YellowDog.Netboot.Device.PersistenceTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.Device
  alias YellowDog.Netboot.Device.Persistence
  alias YellowDog.Netboot.ManagedStorage.TestFileOps

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "netboot_device_persistence_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, managed_path: Path.join(root, "managed_devices.json")}
  end

  describe "save/3 and load/2" do
    test "round-trips the complete Device struct losslessly in versioned JSON", %{
      managed_path: managed_path
    } do
      first_seen = ~U[2026-07-16 01:02:03.123456Z]
      last_seen = ~U[2026-07-16 04:05:06.654321Z]

      device = %Device{
        mac: "AA:BB:CC:DD:EE:FF",
        uuid: "device-1",
        hostname: "server-1",
        arch: :aarch64,
        profile_id: "installer",
        ip_address: {2001, 3512, 0, 0, 0, 0, 0, 42},
        state: :failed,
        hardware_info: %{
          "cpu" => "Neoverse",
          :memory => %{bytes: 68_719_476_736},
          "disk_layout" => {:gpt, 2}
        },
        first_seen: first_seen,
        last_seen: last_seen,
        install_attempts: 3,
        last_error: "installer timeout",
        tags: ["rack-2", "gpu"],
        state_history: [
          %{state: :failed, at: last_seen},
          %{state: :booting, at: first_seen}
        ],
        slot: %{active: :b, pending: :a},
        rescue_mode: true
      }

      assert :ok = Persistence.save(managed_path, [device])
      assert {:ok, [^device]} = Persistence.load(managed_path)

      assert %{"version" => 1, "devices" => [stored]} =
               managed_path |> File.read!() |> Jason.decode!()

      assert stored["uuid"] == "device-1"
      assert stored["hardware_info"] != nil
      assert stored["state_history"] != nil
      assert stored["slot"] == %{"active" => "b", "pending" => "a"}
      assert stored["rescue_mode"] == true
    end

    test "stores an empty managed snapshot", %{managed_path: managed_path} do
      assert :ok = Persistence.save(managed_path, [])
      assert {:ok, []} = Persistence.load(managed_path)
      assert %{"version" => 1, "devices" => []} = Jason.decode!(File.read!(managed_path))
    end
  end

  describe "load/2 validation" do
    test "returns an empty snapshot when the managed sidecar is missing", %{root: root} do
      assert {:ok, []} = Persistence.load(Path.join(root, "missing.json"))
    end

    test "rejects malformed managed JSON", %{managed_path: managed_path} do
      File.write!(managed_path, "{")
      assert {:error, :invalid_json} = Persistence.load(managed_path)
    end

    test "rejects unsupported versions", %{managed_path: managed_path} do
      File.write!(managed_path, Jason.encode!(%{"version" => 2, "devices" => []}))
      assert {:error, :unsupported_version} = Persistence.load(managed_path)
    end

    test "rejects incomplete devices", %{managed_path: managed_path} do
      File.write!(
        managed_path,
        Jason.encode!(%{"version" => 1, "devices" => [%{"mac" => "AA:BB:CC:DD:EE:FF"}]})
      )

      assert {:error, :invalid_snapshot} = Persistence.load(managed_path)
    end

    test "rejects duplicate UUID or normalized MAC ownership", %{managed_path: managed_path} do
      first = Device.new("AA:BB:CC:DD:EE:01", %{uuid: "device-1"})
      duplicate_uuid = Device.new("AA:BB:CC:DD:EE:02", %{uuid: "device-1"})
      duplicate_mac = Device.new("aa-bb-cc-dd-ee-01", %{uuid: "device-2"})

      assert :ok = Persistence.save(managed_path, [first])
      [%{"devices" => [encoded]}] = [Jason.decode!(File.read!(managed_path))]

      File.write!(
        managed_path,
        Jason.encode!(%{"version" => 1, "devices" => [encoded, encode_device(duplicate_uuid)]})
      )

      assert {:error, :invalid_snapshot} = Persistence.load(managed_path)

      File.write!(
        managed_path,
        Jason.encode!(%{"version" => 1, "devices" => [encoded, encode_device(duplicate_mac)]})
      )

      assert {:error, :invalid_snapshot} = Persistence.load(managed_path)
    end
  end

  describe "load_legacy/1" do
    test "loads the prior TOML representation as fallback devices", %{root: root} do
      path = Path.join(root, "devices.toml")

      File.write!(
        path,
        """
        [devices.AA_BB_CC_DD_EE_FF]
        mac = "aa-bb-cc-dd-ee-ff"
        uuid = "legacy-device"
        hostname = "legacy-host"
        arch = "x86_64"
        profile_id = "legacy-profile"
        state = "installed"
        install_attempts = 2
        tags = ["legacy"]
        """
      )

      assert {:ok, [device]} = Persistence.load_legacy(path)
      assert device.mac == "AA:BB:CC:DD:EE:FF"
      assert device.uuid == "legacy-device"
      assert device.hostname == "legacy-host"
      assert device.arch == :x86_64
      assert device.profile_id == "legacy-profile"
      assert device.state == :installed
      assert device.install_attempts == 2
      assert device.tags == ["legacy"]
    end

    test "returns an empty list when the legacy file is missing", %{root: root} do
      assert {:ok, []} = Persistence.load_legacy(Path.join(root, "missing.toml"))
    end
  end

  describe "atomic replacement" do
    for phase <- [:write, :sync, :close, :rename] do
      test "#{phase} failure preserves the prior sidecar and removes the temporary file", %{
        root: root,
        managed_path: managed_path
      } do
        prior = Device.new("AA:BB:CC:DD:EE:01", %{uuid: "device-1"})
        candidate = Device.new("AA:BB:CC:DD:EE:02", %{uuid: "device-2"})

        assert :ok = Persistence.save(managed_path, [prior])
        prior_bytes = File.read!(managed_path)

        assert {:error, unquote(:"#{phase}_failed")} =
                 Persistence.save(managed_path, [candidate],
                   file_ops: {TestFileOps, %{fail: unquote(phase)}}
                 )

        assert File.read!(managed_path) == prior_bytes
        assert [] == Path.wildcard(Path.join(root, ".managed_devices.json.*.tmp"))
      end
    end
  end

  defp encode_device(device) do
    path =
      Path.join(
        System.tmp_dir!(),
        "encoded_device_#{System.unique_integer([:positive])}.json"
      )

    try do
      assert :ok = Persistence.save(path, [device])
      %{"devices" => [encoded]} = Jason.decode!(File.read!(path))
      encoded
    after
      File.rm(path)
    end
  end
end
