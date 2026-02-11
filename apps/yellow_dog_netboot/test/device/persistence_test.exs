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
  end
end
