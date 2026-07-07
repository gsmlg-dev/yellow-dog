defmodule YellowDog.Server.ServiceRegistry do
  @moduledoc """
  Registry of services that can run inside a `yellow_dog_server` runtime.

  The registry is intentionally metadata-only. It can describe services whose
  OTP applications are not present in the current release yet, such as the
  future server agent, without forcing a compile-time dependency on them.
  """

  @services [
    %{
      name: :dns,
      label: "DNS",
      application: :yellow_dog_dns,
      module: YellowDog.Dns,
      supervisor: YellowDog.Dns.Supervisor,
      process_name: YellowDog.Dns,
      controllable?: true
    },
    %{
      name: :mdns,
      label: "mDNS",
      application: :yellow_dog_mdns,
      module: YellowDog.Mdns,
      supervisor: YellowDog.Mdns.Supervisor,
      process_name: YellowDog.Mdns,
      controllable?: true
    },
    %{
      name: :dhcpv4,
      label: "DHCPv4",
      application: :yellow_dog_dhcpv4,
      module: YellowDog.Dhcpv4,
      supervisor: YellowDog.Dhcpv4.Supervisor,
      process_name: YellowDog.Dhcpv4,
      controllable?: true
    },
    %{
      name: :dhcpv6,
      label: "DHCPv6",
      application: :yellow_dog_dhcpv6,
      module: YellowDog.Dhcpv6,
      supervisor: YellowDog.Dhcpv6.Supervisor,
      process_name: YellowDog.Dhcpv6,
      controllable?: true
    },
    %{
      name: :netboot,
      label: "Netboot",
      application: :yellow_dog_netboot,
      module: YellowDog.Netboot.Supervisor,
      supervisor: YellowDog.Netboot.Supervisor,
      process_name: YellowDog.Netboot.Supervisor,
      controllable?: true
    },
    %{
      name: :identity,
      label: "Identity",
      application: :yellow_dog_identity,
      module: YellowDogIdentity,
      supervisor: YellowDogIdentity.Supervisor,
      process_name: YellowDogIdentity.Supervisor,
      controllable?: true
    },
    %{
      name: :fingerprint,
      label: "Fingerprint",
      application: :yellow_dog_fingerprint,
      module: YellowDog.Fingerprint.Supervisor,
      supervisor: YellowDog.Fingerprint.Supervisor,
      process_name: YellowDog.Fingerprint.Supervisor,
      controllable?: true
    },
    %{
      name: :server_agent,
      label: "Server Agent",
      application: :yellow_dog_server_agent,
      module: YellowDog.ServerAgent,
      supervisor: YellowDog.ServerAgent.Supervisor,
      process_name: YellowDog.ServerAgent.Supervisor,
      controllable?: false
    }
  ]

  @doc """
  Returns all service metadata in stable startup/display order.
  """
  @spec all() :: [map()]
  def all do
    Enum.map(@services, &put_availability/1)
  end

  @doc """
  Returns all known service names in stable order.
  """
  @spec list_services() :: [atom()]
  def list_services do
    Enum.map(@services, & &1.name)
  end

  @doc """
  Fetches metadata for a known service.
  """
  @spec fetch(atom()) :: {:ok, map()} | :error
  def fetch(service) when is_atom(service) do
    case Enum.find(@services, &(&1.name == service)) do
      nil -> :error
      metadata -> {:ok, put_availability(metadata)}
    end
  end

  def fetch(_service), do: :error

  @doc """
  Returns true when the service is listed in the registry.
  """
  @spec known?(term()) :: boolean()
  def known?(service) do
    match?({:ok, _metadata}, fetch(service))
  end

  defp put_availability(metadata) do
    Map.put(metadata, :available?, Code.ensure_loaded?(metadata.module))
  end
end
