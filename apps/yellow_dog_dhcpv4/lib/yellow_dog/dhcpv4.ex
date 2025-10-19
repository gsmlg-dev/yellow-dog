defmodule YellowDog.Dhcpv4 do
  @moduledoc """
  DHCPv4 supervisor that manages DHCPv4 protocol implementation.
  """

  @doc """
  Starts the Dhcpv4 supervisor.

  Delegates to `YellowDog.Dhcpv4.Supervisor.start_link/1`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(options), to: YellowDog.Dhcpv4.Supervisor

  @doc """
  Returns a child specification for the Dhcpv4 supervisor.

  Delegates to `YellowDog.Dhcpv4.Supervisor.child_spec/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: YellowDog.Dhcpv4.Supervisor
end
