defmodule YellowDog.Netboot.Boot.ArchTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.Boot.Arch

  describe "from_option93/1" do
    test "BIOS x86 (0x0000)" do
      assert {:ok, :bios_x86, "undionly.kpxe"} = Arch.from_option93(0x0000)
    end

    test "UEFI x86 (0x0006)" do
      assert {:ok, :x86_64, "ipxe.efi"} = Arch.from_option93(0x0006)
    end

    test "UEFI x64 (0x0007)" do
      assert {:ok, :x86_64, "ipxe.efi"} = Arch.from_option93(0x0007)
    end

    test "UEFI x64 (0x0009)" do
      assert {:ok, :x86_64, "ipxe.efi"} = Arch.from_option93(0x0009)
    end

    test "UEFI ARM64 (0x000B)" do
      assert {:ok, :aarch64, "ipxe-arm64.efi"} = Arch.from_option93(0x000B)
    end

    test "unknown architecture" do
      assert :unknown = Arch.from_option93(0xFFFF)
    end
  end

  describe "from_string/1" do
    test "x86_64" do
      assert :x86_64 = Arch.from_string("x86_64")
    end

    test "amd64 alias" do
      assert :x86_64 = Arch.from_string("amd64")
    end

    test "aarch64" do
      assert :aarch64 = Arch.from_string("aarch64")
    end

    test "arm64 alias" do
      assert :aarch64 = Arch.from_string("arm64")
    end

    test "bios_x86" do
      assert :bios_x86 = Arch.from_string("bios_x86")
    end

    test "bios alias" do
      assert :bios_x86 = Arch.from_string("bios")
    end

    test "unknown returns nil" do
      assert nil == Arch.from_string("sparc")
    end
  end

  describe "boot_file/1" do
    test "bios_x86 → undionly.kpxe" do
      assert "undionly.kpxe" = Arch.boot_file(:bios_x86)
    end

    test "x86_64 → ipxe.efi" do
      assert "ipxe.efi" = Arch.boot_file(:x86_64)
    end

    test "aarch64 → ipxe-arm64.efi" do
      assert "ipxe-arm64.efi" = Arch.boot_file(:aarch64)
    end

    test "unknown → nil" do
      assert nil == Arch.boot_file(:sparc)
    end
  end

  test "known_codes/0 returns expected codes" do
    codes = Arch.known_codes()
    assert 0x0000 in codes
    assert 0x0007 in codes
    assert 0x000B in codes
  end
end
