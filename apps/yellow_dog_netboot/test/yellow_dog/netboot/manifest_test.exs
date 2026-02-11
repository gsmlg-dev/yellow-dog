defmodule YellowDog.Netboot.ManifestTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.Manifest

  describe "from_config/1" do
    test "creates manifest from full config" do
      config = %{
        "profile" => "nixos-minimal",
        "disk_layout" => "single-root-btrfs",
        "flake" => "github:user/system#x86_64-linux",
        "slot_strategy" => "dual",
        "post_install_hooks" => ["cleanup.sh", "notify.sh"]
      }

      manifest = Manifest.from_config(config)

      assert manifest.profile == "nixos-minimal"
      assert manifest.disk_layout == "single-root-btrfs"
      assert manifest.flake == "github:user/system#x86_64-linux"
      assert manifest.slot_strategy == "dual"
      assert manifest.post_install_hooks == ["cleanup.sh", "notify.sh"]
    end

    test "creates manifest with minimal config and defaults" do
      config = %{"profile" => "rescue"}

      manifest = Manifest.from_config(config)

      assert manifest.profile == "rescue"
      assert manifest.disk_layout == nil
      assert manifest.flake == nil
      assert manifest.slot_strategy == "single"
      assert manifest.post_install_hooks == []
    end

    test "overrides slot_strategy default" do
      config = %{
        "profile" => "test",
        "slot_strategy" => "ab_redundant"
      }

      manifest = Manifest.from_config(config)

      assert manifest.slot_strategy == "ab_redundant"
    end

    test "overrides post_install_hooks default" do
      config = %{
        "profile" => "test",
        "post_install_hooks" => ["hook1.sh"]
      }

      manifest = Manifest.from_config(config)

      assert manifest.post_install_hooks == ["hook1.sh"]
    end

    test "handles empty config map" do
      config = %{}

      manifest = Manifest.from_config(config)

      assert manifest.profile == nil
      assert manifest.disk_layout == nil
      assert manifest.flake == nil
      assert manifest.slot_strategy == "single"
      assert manifest.post_install_hooks == []
    end
  end

  describe "to_map/1" do
    test "serializes full manifest to map" do
      manifest = %Manifest{
        profile: "nixos-desktop",
        disk_layout: "lvm-encrypted",
        flake: "github:org/infra#server",
        slot_strategy: "dual",
        post_install_hooks: ["reboot.sh"]
      }

      map = Manifest.to_map(manifest)

      assert map == %{
               "profile" => "nixos-desktop",
               "disk_layout" => "lvm-encrypted",
               "flake" => "github:org/infra#server",
               "slot_strategy" => "dual",
               "post_install_hooks" => ["reboot.sh"]
             }
    end

    test "serializes minimal manifest with nils" do
      manifest = %Manifest{
        profile: "basic",
        disk_layout: nil,
        flake: nil,
        slot_strategy: "single",
        post_install_hooks: []
      }

      map = Manifest.to_map(manifest)

      assert map == %{
               "profile" => "basic",
               "disk_layout" => nil,
               "flake" => nil,
               "slot_strategy" => "single",
               "post_install_hooks" => []
             }
    end
  end

  describe "round-trip conversion" do
    test "from_config and to_map are inverses" do
      original_config = %{
        "profile" => "test-profile",
        "disk_layout" => "zfs-raidz",
        "flake" => "github:test/repo",
        "slot_strategy" => "triple",
        "post_install_hooks" => ["a.sh", "b.sh", "c.sh"]
      }

      manifest = Manifest.from_config(original_config)
      converted_back = Manifest.to_map(manifest)

      assert converted_back == original_config
    end

    test "round-trip preserves defaults" do
      config = %{"profile" => "minimal"}

      manifest = Manifest.from_config(config)
      map = Manifest.to_map(manifest)

      assert map["profile"] == "minimal"
      assert map["slot_strategy"] == "single"
      assert map["post_install_hooks"] == []
    end
  end
end
