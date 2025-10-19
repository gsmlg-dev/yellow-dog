defmodule YellowDog.Mdns do
  @moduledoc """
  mDNS supervisor that manages multicast DNS functionality.
  """

  @doc """
  Starts the Mdns supervisor.

  Delegates to `YellowDog.Mdns.Supervisor.start_link/1`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(options), to: YellowDog.Mdns.Supervisor

  @doc """
  Returns a child specification for the Mdns supervisor.

  Delegates to `YellowDog.Mdns.Supervisor.child_spec/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: YellowDog.Mdns.Supervisor
end
