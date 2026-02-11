defmodule YellowDog.Netboot.Device.PersistenceTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.Device
  alias YellowDog.Netboot.Device.Persistence

  @tmp_path System.tmp_dir!() |> Path.join("netboot_persistence_test.toml")

  setup do
    on_exit(fn -> File.rm(@tmp_path) end)
    :ok
  end

  describe "save/2 and load/2" do
    test "round-trips device list" do
      devices = [
        %{
          Device.new("AA:BB:CC:DD:EE:01")
          | hostname: "server1",
            profile_id: "nixos-minimal",
            arch: :x86_64
        },
        %{
          Device.new("AA:BB:CC:DD:EE:02")
          | hostname: "server2",
            state: :installed,
            tags: ["rack1"]
        }
      ]

      assert :ok = Persistence.save(@tmp_path, devices)
      assert {:ok, loaded} = Persistence.load(@tmp_path)
      assert length(loaded) == 2

      s1 = Enum.find(loaded, &(&1.mac == "AA:BB:CC:DD:EE:01"))
      assert s1.hostname == "server1"
      assert s1.profile_id == "nixos-minimal"
      assert s1.arch == :x86_64
    end
  end

  describe "load/1" do
    test "returns empty list for non-existent file" do
      assert {:ok, []} = Persistence.load("/nonexistent/path.toml")
    end

    test "returns empty list for empty TOML" do
      path = Path.join(System.tmp_dir!(), "empty_#{System.unique_integer([:positive])}.toml")
      File.write!(path, "")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, []} = Persistence.load(path)
    end

    test "returns empty list for TOML without devices key" do
      path = Path.join(System.tmp_dir!(), "nodevices_#{System.unique_integer([:positive])}.toml")
      File.write!(path, "[other]\nkey = \"value\"")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, []} = Persistence.load(path)
    end

    test "returns error for invalid TOML" do
      path = Path.join(System.tmp_dir!(), "bad_#{System.unique_integer([:positive])}.toml")
      File.write!(path, "this is not valid TOML {{{ @@@ [[[")
      on_exit(fn -> File.rm(path) end)

      assert {:error, _} = Persistence.load(path)
    end
  end

  describe "save/2 edge cases" do
    test "saves device with nil optional fields" do
      devices = [Device.new("AA:BB:CC:DD:EE:FF")]
      path = Path.join(System.tmp_dir!(), "nil_fields_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      assert :ok = Persistence.save(path, devices)
      content = File.read!(path)
      assert String.contains?(content, "AA:BB:CC:DD:EE:FF")
      refute String.contains?(content, "uuid =")
    end

    test "saves device with all fields populated" do
      device = %{
        Device.new("11:22:33:44:55:66")
        | uuid: "uuid-123",
          hostname: "host1",
          arch: :aarch64,
          profile_id: "nixos",
          last_error: "timeout",
          state: :failed,
          install_attempts: 3,
          tags: ["gpu", "rack2"]
      }

      path = Path.join(System.tmp_dir!(), "full_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      assert :ok = Persistence.save(path, [device])
      content = File.read!(path)
      assert String.contains?(content, "uuid-123")
      assert String.contains?(content, "host1")
      assert String.contains?(content, "aarch64")
      assert String.contains?(content, "nixos")
      assert String.contains?(content, "timeout")
    end

    test "saves empty device list" do
      path = Path.join(System.tmp_dir!(), "empty_devs_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      assert :ok = Persistence.save(path, [])
      assert File.read!(path) == ""
    end
  end

  describe "round-trip with state parsing" do
    test "preserves valid states through save/load" do
      device = %{Device.new("AA:BB:CC:DD:EE:FF") | state: :failed, last_error: "disk"}

      path = Path.join(System.tmp_dir!(), "states_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)

      assert :ok = Persistence.save(path, [device])
      assert {:ok, [loaded]} = Persistence.load(path)
      assert loaded.state == :failed
      assert loaded.last_error == "disk"
    end
  end
end
