defmodule YellowDog.Netman.Types.DesiredState do
  @moduledoc """
  Represents the desired network configuration derived from profiles.
  """

  alias YellowDog.Netman.Types.Profile

  @type connection :: %{
          profile_id: String.t(),
          interface: String.t(),
          ipv4: Profile.ipv4_config(),
          ipv6: Profile.ipv6_config(),
          mtu: pos_integer() | nil,
          priority: integer(),
          dns: [String.t()]
        }

  @type t :: %__MODULE__{
          connections: %{String.t() => connection()}
        }

  defstruct connections: %{}

  @doc "Creates a desired state from a list of matched profiles."
  @spec from_profiles([{Profile.t(), String.t()}]) :: t()
  def from_profiles(profile_interface_pairs) do
    connections =
      for {profile, interface} <- profile_interface_pairs, into: %{} do
        dns = profile.ipv4.dns ++ profile.ipv6.dns

        connection = %{
          profile_id: profile.id,
          interface: interface,
          ipv4: profile.ipv4,
          ipv6: profile.ipv6,
          mtu: profile.ethernet.mtu,
          priority: profile.autoconnect_priority,
          dns: dns
        }

        {profile.id, connection}
      end

    %__MODULE__{connections: connections}
  end
end
