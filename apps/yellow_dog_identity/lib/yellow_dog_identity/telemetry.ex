defmodule YellowDogIdentity.Telemetry do
  @moduledoc """
  Telemetry event helpers for the identity service.

  All events follow the `[:yellow_dog, :identity, ...]` prefix convention.
  """

  @doc """
  Emits a registration start event.
  """
  def registration_start(hostname, source_ip, trust_level \\ :unverified) do
    :telemetry.execute(
      [:yellow_dog, :identity, :register, :start],
      %{system_time: System.system_time()},
      %{hostname: hostname, source_ip: format_ip(source_ip), trust_level: trust_level}
    )
  end

  @doc """
  Emits a registration stop (success) event.
  """
  def registration_stop(duration, metadata) do
    :telemetry.execute(
      [:yellow_dog, :identity, :register, :stop],
      %{duration: duration},
      metadata
    )
  end

  @doc """
  Emits a registration exception event.
  """
  def registration_exception(duration, hostname, reason) do
    :telemetry.execute(
      [:yellow_dog, :identity, :register, :exception],
      %{duration: duration},
      %{hostname: hostname, reason: reason}
    )
  end

  @doc """
  Emits an approval event.
  """
  def host_approved(host_id, approved_by, trust_level) do
    :telemetry.execute(
      [:yellow_dog, :identity, :approve],
      %{count: 1},
      %{host_id: host_id, approved_by: approved_by, trust_level: trust_level}
    )
  end

  @doc """
  Emits a revocation event.
  """
  def host_revoked(host_id, revoked_by, reason) do
    :telemetry.execute(
      [:yellow_dog, :identity, :revoke],
      %{count: 1},
      %{host_id: host_id, revoked_by: revoked_by, reason: reason}
    )
  end

  @doc """
  Emits a host deleted event.
  """
  def host_deleted(host_id, hostname) do
    :telemetry.execute(
      [:yellow_dog, :identity, :delete],
      %{count: 1},
      %{host_id: host_id, hostname: hostname}
    )
  end

  @doc """
  Emits a DHCP correlation match event.
  """
  def correlation_match(source_ip, mac, fingerprint_class, trust_level) do
    :telemetry.execute(
      [:yellow_dog, :identity, :correlation, :match],
      %{count: 1},
      %{
        source_ip: format_ip(source_ip),
        mac: mac,
        fingerprint_class: fingerprint_class,
        trust_level: trust_level
      }
    )
  end

  @doc """
  Emits a DHCP correlation miss event.
  """
  def correlation_miss(source_ip, reason) do
    :telemetry.execute(
      [:yellow_dog, :identity, :correlation, :miss],
      %{count: 1},
      %{source_ip: format_ip(source_ip), reason: reason}
    )
  end

  @doc """
  Emits a cloud attestation verify event.
  """
  def attestation_verify(duration, provider, account_id, instance_id, result) do
    :telemetry.execute(
      [:yellow_dog, :identity, :attestation, :verify],
      %{duration: duration},
      %{provider: provider, account_id: account_id, instance_id: instance_id, result: result}
    )
  end

  @doc """
  Emits a cloud attestation reject event.
  """
  def attestation_reject(provider, reason, source_ip) do
    :telemetry.execute(
      [:yellow_dog, :identity, :attestation, :reject],
      %{count: 1},
      %{provider: provider, reason: reason, source_ip: format_ip(source_ip)}
    )
  end

  @doc """
  Emits a recipient export event.
  """
  def export_recipients(count, duration) do
    :telemetry.execute(
      [:yellow_dog, :identity, :export, :recipients],
      %{count: count, duration: duration},
      %{}
    )
  end

  @doc """
  Emits a trust provider untrusted event (explicit rejection).
  """
  def trust_untrusted(provider, reason, hostname) do
    :telemetry.execute(
      [:yellow_dog, :identity, :trust, :untrusted],
      %{count: 1},
      %{provider: provider, reason: reason, hostname: hostname}
    )
  end

  @doc """
  Emits a trust resolution event (final result of trust chain).
  """
  def trust_resolved(duration, trust_level, provider, hostname) do
    :telemetry.execute(
      [:yellow_dog, :identity, :trust, :resolved],
      %{duration: duration},
      %{trust_level: trust_level, provider: provider, hostname: hostname}
    )
  end

  defp format_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: "unknown"
end
