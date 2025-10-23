defmodule DNS.Message.EDNS0.Option.UpdateLease do
  @moduledoc """
  EDNS0.Option.UpdateLease [RFC-ietf-dnssd-update-lease-08]

  The Update Lease option is used in DNS-SD (DNS Service Discovery)
  to indicate the lease duration for resource record updates.

  Option Format:

                        1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |        OPTION-CODE = 2        |       OPTION-LENGTH = 4       |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                       LEASE-LIFETIME                         |
    |                                                               |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  - LEASE-LIFETIME: 4 octets, lease duration in seconds
  """
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 4,
          data: lease_lifetime :: 0..4_294_967_295
        }

  defstruct code: OptionCode.new(2), length: 4, data: nil

  @spec new(integer()) :: t()
  def new(lease_lifetime) do
    %__MODULE__{data: lease_lifetime}
  end

  def from_iodata(<<2::16, 4::16, lease_lifetime::32>>) do
    %__MODULE__{data: lease_lifetime}
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option.UpdateLease do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option.UpdateLease{data: lease_lifetime}) do
      <<2::16, 4::16, lease_lifetime::32>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option.UpdateLease do
    def to_string(%DNS.Message.EDNS0.Option.UpdateLease{code: code, data: lease_lifetime}) do
      "#{code}: #{lease_lifetime}s"
    end
  end
end
