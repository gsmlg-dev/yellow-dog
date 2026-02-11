defmodule YellowDog.Netboot.Boot.Profile do
  @moduledoc """
  Boot profile struct and DHCP integration API.

  A boot profile defines the kernel, initrd, and arguments
  for a specific installation type.
  """

  defstruct [
    :id,
    :description,
    :kernel,
    :initrd,
    :kernel_args,
    :installer_image,
    arch: [],
    manifest: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t() | nil,
          kernel: String.t(),
          initrd: String.t(),
          kernel_args: String.t() | nil,
          installer_image: String.t() | nil,
          arch: [atom()],
          manifest: map()
        }

  @doc "Create a profile from a TOML config map."
  @spec from_config(String.t(), map()) :: t()
  def from_config(id, config) do
    %__MODULE__{
      id: id,
      description: Map.get(config, "description"),
      kernel: Map.get(config, "kernel", ""),
      initrd: Map.get(config, "initrd", ""),
      kernel_args: Map.get(config, "kernel_args"),
      installer_image: Map.get(config, "installer_image"),
      arch: parse_arch_list(Map.get(config, "arch", [])),
      manifest: Map.get(config, "manifest", %{})
    }
  end

  @doc """
  Determine boot configuration for a device.

  Called by DHCP handler during OFFER/ACK construction to inject
  boot options (Option 66/67).
  """
  @spec for_device(String.t(), atom() | nil) ::
          {:ok, map()} | :no_boot
  def for_device(mac, arch \\ nil) do
    alias YellowDog.Netboot.Device.Registry
    alias YellowDog.Netboot.Manifest.Store
    alias YellowDog.Netboot.Boot.Arch

    with {:ok, device} <- Registry.get(mac),
         profile_id when not is_nil(profile_id) <- device.profile_id,
         {:ok, profile} <- Store.get_profile(profile_id) do
      boot_file = Arch.boot_file(arch || device.arch || :x86_64) || "ipxe.efi"

      {:ok,
       %{
         boot_mode: :tftp,
         filename: boot_file,
         server: tftp_server_address(),
         profile: profile
       }}
    else
      _ -> :no_boot
    end
  end

  defp parse_arch_list(list) when is_list(list) do
    Enum.map(list, fn
      arch when is_atom(arch) -> arch
      arch when is_binary(arch) -> YellowDog.Netboot.Boot.Arch.from_string(arch) || :x86_64
    end)
  end

  defp parse_arch_list(_), do: []

  defp tftp_server_address do
    Application.get_env(:yellow_dog_netboot, :tftp_server_address, "0.0.0.0")
  end
end
