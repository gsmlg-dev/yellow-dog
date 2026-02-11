defmodule YellowDog.Netboot.Boot.Arch do
  @moduledoc """
  Architecture detection helpers for PXE boot.

  Maps DHCP Option 93 (Client System Architecture) to boot file paths
  and architecture atoms.
  """

  @arch_map %{
    0x0000 => {:bios_x86, "undionly.kpxe"},
    0x0006 => {:x86_64, "ipxe.efi"},
    0x0007 => {:x86_64, "ipxe.efi"},
    0x0009 => {:x86_64, "ipxe.efi"},
    0x000B => {:aarch64, "ipxe-arm64.efi"}
  }

  @doc "Detect architecture from DHCP Option 93 value."
  @spec from_option93(non_neg_integer()) :: {:ok, atom(), String.t()} | :unknown
  def from_option93(code) when is_integer(code) do
    case Map.get(@arch_map, code) do
      {arch, boot_file} -> {:ok, arch, boot_file}
      nil -> :unknown
    end
  end

  @doc "Detect architecture from a string identifier."
  @spec from_string(String.t()) :: atom() | nil
  def from_string("x86_64"), do: :x86_64
  def from_string("amd64"), do: :x86_64
  def from_string("aarch64"), do: :aarch64
  def from_string("arm64"), do: :aarch64
  def from_string("bios"), do: :bios_x86
  def from_string("bios_x86"), do: :bios_x86
  def from_string(_), do: nil

  @doc "Get the default boot filename for an architecture."
  @spec boot_file(atom()) :: String.t() | nil
  def boot_file(:bios_x86), do: "undionly.kpxe"
  def boot_file(:x86_64), do: "ipxe.efi"
  def boot_file(:aarch64), do: "ipxe-arm64.efi"
  def boot_file(_), do: nil

  @doc "Return all known architecture codes."
  @spec known_codes() :: [non_neg_integer()]
  def known_codes, do: Map.keys(@arch_map)
end
