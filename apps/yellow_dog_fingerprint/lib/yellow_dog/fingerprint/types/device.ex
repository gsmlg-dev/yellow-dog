defmodule YellowDog.Fingerprint.Types.Device do
  @moduledoc """
  An observed network entity. Correlates DHCPv4 and DHCPv6 observations
  using MAC address as the primary key.
  """

  @type t :: %__MODULE__{
          id: binary(),
          mac: String.t(),
          oui_vendor: String.t() | nil,
          duid: binary() | nil,
          ipv4_addresses: [String.t()],
          ipv6_addresses: [String.t()],
          hostname: String.t() | nil,
          fingerprint_v4_id: binary() | nil,
          fingerprint_v6_id: binary() | nil,
          profile_id: String.t() | nil,
          profile_confidence: non_neg_integer(),
          first_seen: DateTime.t(),
          last_seen: DateTime.t(),
          observation_count: non_neg_integer(),
          metadata: map()
        }

  defstruct [
    :id,
    :mac,
    :oui_vendor,
    :duid,
    :hostname,
    :fingerprint_v4_id,
    :fingerprint_v6_id,
    :profile_id,
    :first_seen,
    :last_seen,
    ipv4_addresses: [],
    ipv6_addresses: [],
    profile_confidence: 0,
    observation_count: 0,
    metadata: %{}
  ]
end
