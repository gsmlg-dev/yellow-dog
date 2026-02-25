defmodule YellowDogIdentity.Trust.DHCP.Correlation do
  @moduledoc """
  DHCP correlation trust provider.

  Verifies registration by correlating the source IP address with an active
  DHCP lease. Provides `network_verified` (with fingerprint match) or
  `network_partial` (lease only) trust levels.
  """

  @behaviour YellowDogIdentity.Trust.Provider

  alias YellowDogIdentity.Trust.DHCP.LeaseCache

  @default_grace_window_seconds 30

  @impl true
  def verify(%{source_ip: source_ip} = context) do
    # Check if DHCP correlation is applicable
    case LeaseCache.lookup(source_ip) do
      {:ok, lease_entry} ->
        verify_lease(lease_entry, context)

      :not_found ->
        # Check if DHCP is configured at all
        if dhcp_configured?() do
          YellowDogIdentity.Telemetry.correlation_miss(source_ip, :no_lease)
          {:untrusted, :no_lease}
        else
          {:skip, :not_applicable}
        end
    end
  end

  defp verify_lease(lease_entry, context) do
    now = System.monotonic_time(:second)
    lease_age = now - lease_entry.lease_start
    grace_window = get_grace_window()

    cond do
      # Lease expired (with grace window)
      lease_age > lease_entry.lease_duration + grace_window ->
        YellowDogIdentity.Telemetry.correlation_miss(context.source_ip, :expired)
        {:untrusted, :expired}

      # Has fingerprint and it matches expected class
      lease_entry.fingerprint_class && fingerprint_matches?(lease_entry, context) ->
        evidence = build_evidence(lease_entry)

        YellowDogIdentity.Telemetry.correlation_match(
          context.source_ip,
          lease_entry.mac,
          lease_entry.fingerprint_class,
          :network_verified
        )

        {:trusted, :network_verified, evidence}

      # Has fingerprint but doesn't match the configured allowlist
      lease_entry.fingerprint_class && get_allowed_fingerprint_classes() != [] ->
        YellowDogIdentity.Telemetry.correlation_miss(context.source_ip, :fingerprint_mismatch)
        {:untrusted, :fingerprint_mismatch}

      # No fingerprint data or no allowlist configured — partial trust
      true ->
        evidence = build_evidence(lease_entry)

        YellowDogIdentity.Telemetry.correlation_match(
          context.source_ip,
          lease_entry.mac,
          lease_entry.fingerprint_class,
          :network_partial
        )

        {:trusted, :network_partial, evidence}
    end
  end

  defp fingerprint_matches?(lease_entry, _context) do
    allowed = get_allowed_fingerprint_classes()

    cond do
      # No allowlist configured — any fingerprint class matches
      allowed == [] -> lease_entry.fingerprint_class != nil
      # Check against configured allowlist
      lease_entry.fingerprint_class in allowed -> true
      true -> false
    end
  end

  defp get_allowed_fingerprint_classes do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          config = YellowDog.Config.get_all()
          get_in(config, ["identity", "dhcp", "allowed_fingerprint_classes"]) || []
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end

      _ ->
        []
    end
  end

  defp build_evidence(lease_entry) do
    %{
      provider: :dhcp,
      mac: lease_entry.mac,
      assigned_ip: lease_entry.ip,
      fingerprint_class: lease_entry.fingerprint_class,
      lease_start: lease_entry.lease_start,
      lease_duration: lease_entry.lease_duration,
      dhcp_interface: lease_entry.interface
    }
  end

  defp get_grace_window do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          config = YellowDog.Config.get_all()
          get_in(config, ["identity", "dhcp", "grace_window_seconds"]) || @default_grace_window_seconds
        rescue
          _ -> @default_grace_window_seconds
        catch
          :exit, _ -> @default_grace_window_seconds
        end

      _ ->
        @default_grace_window_seconds
    end
  end

  defp dhcp_configured? do
    # Check if DHCP service is enabled via YellowDog.Config
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          YellowDog.Config.service_enabled?(:dhcpv4) or
            YellowDog.Config.service_enabled?(:dhcpv6)
        rescue
          _ -> false
        catch
          :exit, _ -> false
        end

      _ ->
        false
    end
  end
end
