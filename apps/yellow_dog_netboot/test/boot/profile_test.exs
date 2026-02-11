defmodule YellowDog.Netboot.Boot.ProfileTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.Boot.Profile

  describe "from_config/2" do
    test "creates profile from TOML config" do
      config = %{
        "description" => "NixOS Minimal",
        "kernel" => "nixos/bzImage",
        "initrd" => "nixos/initrd.img",
        "kernel_args" => "init=/nix/store/init ip=dhcp",
        "arch" => ["x86_64"],
        "manifest" => %{
          "profile" => "nixos-minimal",
          "disk_layout" => "single-root-btrfs"
        }
      }

      profile = Profile.from_config("nixos-minimal", config)
      assert profile.id == "nixos-minimal"
      assert profile.description == "NixOS Minimal"
      assert profile.kernel == "nixos/bzImage"
      assert profile.initrd == "nixos/initrd.img"
      assert profile.kernel_args == "init=/nix/store/init ip=dhcp"
      assert profile.arch == [:x86_64]
      assert profile.manifest["disk_layout"] == "single-root-btrfs"
    end

    test "handles missing optional fields" do
      profile = Profile.from_config("rescue", %{"kernel" => "rescue/vmlinuz"})
      assert profile.id == "rescue"
      assert profile.kernel == "rescue/vmlinuz"
      assert profile.initrd == ""
      assert profile.arch == []
      assert profile.manifest == %{}
    end

    test "completely empty config uses defaults" do
      profile = Profile.from_config("empty", %{})
      assert profile.id == "empty"
      assert profile.kernel == ""
      assert profile.initrd == ""
      assert profile.kernel_args == nil
      assert profile.installer_image == nil
      assert profile.arch == []
      assert profile.manifest == %{}
    end

    test "parses string arch values" do
      config = %{"arch" => ["x86_64", "aarch64"]}
      profile = Profile.from_config("multi-arch", config)
      assert :x86_64 in profile.arch
      assert :aarch64 in profile.arch
    end

    test "parses atom arch values" do
      config = %{"arch" => [:x86_64]}
      profile = Profile.from_config("atom-arch", config)
      assert profile.arch == [:x86_64]
    end

    test "invalid arch list (non-list) returns empty" do
      config = %{"arch" => "not_a_list"}
      profile = Profile.from_config("bad-arch", config)
      assert profile.arch == []
    end

    test "sets installer_image when provided" do
      config = %{"installer_image" => "nixos/installer.iso"}
      profile = Profile.from_config("with-installer", config)
      assert profile.installer_image == "nixos/installer.iso"
    end

    test "sets description when provided" do
      config = %{"description" => "Test Profile"}
      profile = Profile.from_config("desc", config)
      assert profile.description == "Test Profile"
    end
  end

  describe "for_device/2" do
    test "returns :no_boot when device not found" do
      # Registry doesn't have this MAC
      assert :no_boot = Profile.for_device("ZZ:ZZ:ZZ:ZZ:ZZ:ZZ")
    end
  end
end
