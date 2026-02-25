defmodule YellowDog.DhcpClient.OSIntegration do
  @moduledoc """
  Behaviour for OS-level network configuration after DHCP lease acquisition.

  Implementations handle the platform-specific mechanics of applying a DHCP lease
  to the operating system: assigning IP addresses, configuring routes, and setting
  up DNS resolvers.

  Two implementations are provided:

  - `YellowDog.DhcpClient.OSIntegration.Standalone` -- directly manages the
    interface via `ip` commands (for headless / server environments).
  - `YellowDog.DhcpClient.OSIntegration.HookNM` -- delegates to NetworkManager
    via `nmcli` (for desktop environments where NM owns the interface).
  """

  alias YellowDog.DhcpClient.Lease

  @doc """
  Applies a full lease to the given interface.

  This is the primary entry point after a successful DHCP handshake. Implementations
  should assign the IP address, bring the link up, configure routes and DNS, and
  optionally set the MTU.
  """
  @callback apply_lease(interface :: String.t(), lease :: Lease.t()) :: :ok | {:error, term()}

  @doc """
  Removes all DHCP-managed configuration from the interface.

  Called when the lease expires, the client sends DHCPRELEASE, or the interface
  is taken down. Implementations should remove the assigned IP, default route,
  and DNS configuration.
  """
  @callback deconfigure(interface :: String.t()) :: :ok | {:error, term()}

  @doc """
  Applies routing configuration from the lease.

  Typically adds a default route via the router specified in the lease.
  """
  @callback apply_routes(interface :: String.t(), lease :: Lease.t()) :: :ok | {:error, term()}

  @doc """
  Applies DNS configuration from the lease.

  Writes resolver configuration and notifies the system resolver (e.g. resolvconf,
  systemd-resolved) of the new nameservers and search domain.
  """
  @callback apply_dns(interface :: String.t(), lease :: Lease.t()) :: :ok | {:error, term()}
end
