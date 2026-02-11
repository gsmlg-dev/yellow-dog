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
      # Set up a profile
      profile = %YellowDog.Netboot.Boot.Profile{
        id: "test-profile",
        description: "Test",
        kernel: "vmlinuz",
        initrd: "initrd.img",
        kernel_args: "quiet",
        arch: [:x86_64]
      }

      Store.put_profile(profile)

      # Register device with profile
      {:ok, _} = Registry.register("AA:BB:CC:DD:EE:02", %{arch: :x86_64})
      {:ok, _} = Registry.assign_profile("AA:BB:CC:DD:EE:02", "test-profile")

      # Verify for_device returns boot config
      assert {:ok, %{boot_mode: :tftp, filename: _, server: _, profile: _}} =
               Profile.for_device("AA:BB:CC:DD:EE:02")
    end

    test "for_device/2 respects arch parameter" do
      profile = %YellowDog.Netboot.Boot.Profile{
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
  end
end
