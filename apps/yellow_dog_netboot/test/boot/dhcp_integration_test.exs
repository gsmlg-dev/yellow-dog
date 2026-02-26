defmodule YellowDog.Netboot.Boot.DhcpIntegrationTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netboot.Boot.Profile
  alias YellowDog.Netboot.Device.Registry
  alias YellowDog.Netboot.Manifest.Store

  setup do
    # Clear registries between tests
    if :ets.info(:netboot_device_registry) != :undefined do
      :ets.delete_all_objects(:netboot_device_registry)
    end

    if :ets.info(:netboot_manifest_store) != :undefined do
      :ets.delete_all_objects(:netboot_manifest_store)
    end

    :ok
  end

  # ============================================================================
  # Profile.from_config/2
  # ============================================================================

  describe "Profile.from_config/2" do
    test "creates profile with full config" do
      config = %{
        "description" => "NixOS Installer",
        "kernel" => "vmlinuz-nixos",
        "initrd" => "initrd-nixos.img",
        "kernel_args" => "console=ttyS0,115200n8 quiet",
        "installer_image" => "nixos-installer.iso",
        "arch" => ["x86_64", "aarch64"],
        "manifest" => %{"version" => "24.05"}
      }

      profile = Profile.from_config("nixos-24.05", config)

      assert profile.id == "nixos-24.05"
      assert profile.description == "NixOS Installer"
      assert profile.kernel == "vmlinuz-nixos"
      assert profile.initrd == "initrd-nixos.img"
      assert profile.kernel_args == "console=ttyS0,115200n8 quiet"
      assert profile.installer_image == "nixos-installer.iso"
      assert profile.arch == [:x86_64, :aarch64]
      assert profile.manifest == %{"version" => "24.05"}
    end

    test "creates profile with minimal config" do
      profile = Profile.from_config("minimal", %{})

      assert profile.id == "minimal"
      assert profile.description == nil
      assert profile.kernel == ""
      assert profile.initrd == ""
      assert profile.kernel_args == nil
      assert profile.installer_image == nil
      assert profile.arch == []
      assert profile.manifest == %{}
    end

    test "parses string arch values to atoms" do
      config = %{"arch" => ["x86_64", "aarch64", "bios"]}
      profile = Profile.from_config("arch-test", config)

      assert profile.arch == [:x86_64, :aarch64, :bios_x86]
    end

    test "preserves atom arch values" do
      config = %{"arch" => [:x86_64, :aarch64]}
      profile = Profile.from_config("atom-arch", config)

      assert profile.arch == [:x86_64, :aarch64]
    end

    test "handles unknown arch strings with x86_64 fallback" do
      config = %{"arch" => ["sparc", "mips"]}
      profile = Profile.from_config("unknown-arch", config)

      assert profile.arch == [:x86_64, :x86_64]
    end

    test "handles empty arch list" do
      config = %{"arch" => []}
      profile = Profile.from_config("no-arch", config)

      assert profile.arch == []
    end

    test "handles non-list arch value gracefully" do
      config = %{"arch" => "x86_64"}
      profile = Profile.from_config("string-arch", config)

      assert profile.arch == []
    end

    test "handles amd64 alias" do
      config = %{"arch" => ["amd64"]}
      profile = Profile.from_config("amd64-test", config)

      assert profile.arch == [:x86_64]
    end

    test "handles arm64 alias" do
      config = %{"arch" => ["arm64"]}
      profile = Profile.from_config("arm64-test", config)

      assert profile.arch == [:aarch64]
    end
  end

  # ============================================================================
  # DHCP integration callback
  # ============================================================================

  describe "DHCP integration callback" do
    test "Application env is set on start" do
      assert {YellowDog.Netboot.Boot.Profile, :for_device} ==
               Application.get_env(:yellow_dog_dhcpv4, :boot_options_fn)
    end

    test "for_device/1 returns :no_boot for unknown device" do
      assert :no_boot == Profile.for_device("FF:FF:FF:FF:FF:FF")
    end

    test "for_device/1 returns :no_boot for device with no profile" do
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:01")
      assert :no_boot == Profile.for_device("AA:BB:CC:DD:EE:01")
    end

    test "for_device/1 returns boot config for device with profile" do
      profile = %Profile{
        id: "test-profile",
        description: "Test",
        kernel: "vmlinuz",
        initrd: "initrd.img",
        kernel_args: "quiet",
        arch: [:x86_64]
      }

      Store.put_profile(profile)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:02", %{arch: :x86_64})
      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:02", "test-profile")

      assert {:ok, %{boot_mode: :tftp, filename: _, server: _, profile: _}} =
               Profile.for_device("AA:BB:CC:DD:EE:02")
    end

    test "for_device/2 respects arch parameter" do
      profile = %Profile{
        id: "arch-profile",
        kernel: "vmlinuz",
        initrd: "initrd.img",
        arch: [:aarch64]
      }

      Store.put_profile(profile)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:03")
      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:03", "arch-profile")

      {:ok, result} = Profile.for_device("AA:BB:CC:DD:EE:03", :aarch64)
      assert result.filename =~ "arm" or result.filename =~ "aa64"
    end

    test "for_device/1 returns correct boot filename for x86_64" do
      profile = %Profile{
        id: "x86-profile",
        kernel: "vmlinuz",
        initrd: "initrd.img",
        arch: [:x86_64]
      }

      Store.put_profile(profile)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:10", %{arch: :x86_64})
      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:10", "x86-profile")

      {:ok, result} = Profile.for_device("AA:BB:CC:DD:EE:10")
      assert result.filename == "ipxe.efi"
      assert result.boot_mode == :tftp
    end

    test "for_device/1 returns correct boot filename for bios_x86" do
      profile = %Profile{
        id: "bios-profile",
        kernel: "vmlinuz",
        initrd: "initrd.img",
        arch: [:bios_x86]
      }

      Store.put_profile(profile)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:11", %{arch: :bios_x86})
      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:11", "bios-profile")

      {:ok, result} = Profile.for_device("AA:BB:CC:DD:EE:11")
      assert result.filename == "undionly.kpxe"
    end

    test "for_device/2 arch parameter overrides device arch" do
      profile = %Profile{
        id: "override-profile",
        kernel: "vmlinuz",
        initrd: "initrd.img",
        arch: [:x86_64, :aarch64]
      }

      Store.put_profile(profile)

      # Device registered as x86_64, but caller specifies bios_x86
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:12", %{arch: :x86_64})
      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:12", "override-profile")

      {:ok, result} = Profile.for_device("AA:BB:CC:DD:EE:12", :bios_x86)
      assert result.filename == "undionly.kpxe"
    end

    test "for_device/1 defaults to x86_64 when device has no arch" do
      profile = %Profile{
        id: "noarch-profile",
        kernel: "vmlinuz",
        initrd: "initrd.img",
        arch: []
      }

      Store.put_profile(profile)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:13")
      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:13", "noarch-profile")

      {:ok, result} = Profile.for_device("AA:BB:CC:DD:EE:13")
      # Default x86_64 → ipxe.efi
      assert result.filename == "ipxe.efi"
    end

    test "for_device/1 includes profile in boot config" do
      profile = %Profile{
        id: "profile-check",
        kernel: "vmlinuz-custom",
        initrd: "initrd-custom.img",
        kernel_args: "console=ttyS0",
        arch: [:x86_64]
      }

      Store.put_profile(profile)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:14", %{arch: :x86_64})
      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:14", "profile-check")

      {:ok, result} = Profile.for_device("AA:BB:CC:DD:EE:14")
      assert result.profile.id == "profile-check"
      assert result.profile.kernel == "vmlinuz-custom"
      assert result.profile.kernel_args == "console=ttyS0"
    end

    test "for_device/1 returns :no_boot for deleted profile" do
      profile = %Profile{
        id: "ephemeral-profile",
        kernel: "vmlinuz",
        initrd: "initrd.img",
        arch: [:x86_64]
      }

      Store.put_profile(profile)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:15", %{arch: :x86_64})
      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:15", "ephemeral-profile")

      # Remove profile
      Store.delete_profile("ephemeral-profile")

      assert :no_boot == Profile.for_device("AA:BB:CC:DD:EE:15")
    end

    test "for_device/1 returns server address from config" do
      profile = %Profile{
        id: "server-check",
        kernel: "vmlinuz",
        initrd: "initrd.img",
        arch: [:x86_64]
      }

      Store.put_profile(profile)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:16", %{arch: :x86_64})
      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:16", "server-check")

      {:ok, result} = Profile.for_device("AA:BB:CC:DD:EE:16")
      assert is_binary(result.server)
    end

    test "for_device/2 uses fallback filename for unknown arch" do
      profile = %Profile{
        id: "unknown-arch-profile",
        kernel: "vmlinuz",
        initrd: "initrd.img",
        arch: [:x86_64]
      }

      Store.put_profile(profile)

      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:17", %{arch: :x86_64})
      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:17", "unknown-arch-profile")

      # Pass unknown arch — boot_file returns nil, so fallback to "ipxe.efi"
      {:ok, result} = Profile.for_device("AA:BB:CC:DD:EE:17", :riscv64)
      assert result.filename == "ipxe.efi"
    end
  end
end
