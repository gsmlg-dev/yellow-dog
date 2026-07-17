defmodule YellowDog.Netboot.Manifest.ManagedProfileTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.Manifest.ManagedProfile

  test "round trips every fixed wire field without changing ordered arguments" do
    wire = %{
      "profile_id" => "nixos-aarch64",
      "name" => "NixOS AArch64",
      "boot_asset_id" => "nixos-aarch64-ipxe",
      "arguments" => ["console=ttyAMA0", "ip=dhcp", "console=ttyAMA0"]
    }

    assert {:ok, profile} = ManagedProfile.from_wire(wire)
    assert profile.profile_id == "nixos-aarch64"
    assert profile.name == "NixOS AArch64"
    assert profile.boot_asset_id == "nixos-aarch64-ipxe"
    assert profile.arguments == ["console=ttyAMA0", "ip=dhcp", "console=ttyAMA0"]
    assert ManagedProfile.to_wire(profile) == wire
  end

  test "rejects profiles with a scalar arguments field" do
    assert {:error, :invalid_profile} =
             ManagedProfile.from_wire(%{
               "profile_id" => "nixos",
               "name" => "NixOS",
               "boot_asset_id" => "nixos-ipxe",
               "arguments" => "ip=dhcp"
             })
  end

  test "rejects profiles with missing fixed wire fields" do
    assert {:error, :invalid_profile} =
             ManagedProfile.from_wire(%{
               "profile_id" => "nixos",
               "name" => "NixOS",
               "arguments" => []
             })
  end
end
