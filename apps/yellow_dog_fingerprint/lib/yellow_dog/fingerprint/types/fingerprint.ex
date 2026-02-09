defmodule YellowDog.Fingerprint.Types.Fingerprint do
  @moduledoc """
  A deterministic signature derived from a DHCP message.

  The fingerprint ID is a SHA-256 hash of the canonical form:
  `protocol:param1,param2,...:vendor_class`
  """

  @type t :: %__MODULE__{
          id: binary(),
          protocol: :dhcpv4 | :dhcpv6,
          parameter_list: [non_neg_integer()],
          vendor_class: String.t() | nil,
          hostname_pattern: String.t() | nil,
          first_seen: DateTime.t(),
          last_seen: DateTime.t(),
          hit_count: non_neg_integer()
        }

  defstruct [
    :id,
    :protocol,
    :vendor_class,
    :hostname_pattern,
    :first_seen,
    :last_seen,
    parameter_list: [],
    hit_count: 0
  ]

  @doc """
  Computes the canonical hash for a fingerprint.
  Uses SHA-256 of `protocol:param_list:vendor_class`.
  """
  @spec compute_id(:dhcpv4 | :dhcpv6, [non_neg_integer()], String.t() | nil) :: binary()
  def compute_id(protocol, parameter_list, vendor_class) do
    canonical =
      "#{protocol}:#{Enum.join(parameter_list, ",")}:#{vendor_class || ""}"

    :crypto.hash(:sha256, canonical)
    |> Base.encode16(case: :lower)
  end
end
