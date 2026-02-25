defmodule YellowDogIdentity.Trust.Netboot do
  @moduledoc """
  Netboot trust provider.

  Provides `netboot_verified` trust when the registering host's source IP
  matches an active DHCP lease AND the MAC from that lease has a known
  netboot device record with a boot profile. This represents the strongest
  on-prem trust level: DHCP lease + TFTP boot profile + registration.
  """

  @behaviour YellowDogIdentity.Trust.Provider

  alias YellowDogIdentity.Trust.DHCP.LeaseCache

  @impl true
  def verify(%{source_ip: source_ip} = _context) do
    with {:ok, lease_entry} <- LeaseCache.lookup(source_ip),
         {:ok, device} <- lookup_netboot_device(lease_entry.mac),
         true <- has_boot_profile?(device) do
      evidence = %{
        provider: :netboot,
        mac: lease_entry.mac,
        assigned_ip: lease_entry.ip,
        fingerprint_class: lease_entry.fingerprint_class,
        lease_start: lease_entry.lease_start,
        lease_duration: lease_entry.lease_duration,
        dhcp_interface: lease_entry.interface,
        boot_profile: device_profile_id(device),
        boot_state: device_state(device)
      }

      YellowDogIdentity.Telemetry.correlation_match(
        source_ip,
        lease_entry.mac,
        lease_entry.fingerprint_class,
        :netboot_verified
      )

      {:trusted, :netboot_verified, evidence}
    else
      _ ->
        # Not applicable — fall through to DHCP correlation or other providers
        {:skip, :not_applicable}
    end
  end

  @netboot_registry YellowDog.Netboot.Device.Registry

  defp lookup_netboot_device(mac) do
    case Code.ensure_loaded(@netboot_registry) do
      {:module, mod} ->
        try do
          apply(mod, :get, [mac])
        rescue
          _ -> :not_found
        catch
          :exit, _ -> :not_found
        end

      _ ->
        :not_found
    end
  end

  defp has_boot_profile?(device) do
    device_profile_id(device) != nil
  end

  defp device_profile_id(device) when is_map(device), do: Map.get(device, :profile_id)
  defp device_profile_id(_), do: nil

  defp device_state(device) when is_map(device), do: Map.get(device, :state)
  defp device_state(_), do: nil
end
