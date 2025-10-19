defmodule YellowDog.Dhcpv6 do
  @moduledoc """
  DHCPv6 supervisor that manages DHCPv6 protocol implementation.
  """

  @doc """
  Starts the Dhcpv6 supervisor.

  Delegates to `YellowDog.Dhcpv6.Supervisor.start_link/1`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(options), to: YellowDog.Dhcpv6.Supervisor

  @doc """
  Returns a child specification for the Dhcpv6 supervisor.

  Delegates to `YellowDog.Dhcpv6.Supervisor.child_spec/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: YellowDog.Dhcpv6.Supervisor
end
