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
  end
end
