defmodule DNS.Message.EDNS0.Option.Chain do
  @moduledoc """
  EDNS0.Option.Chain [RFC7901](https://datatracker.ietf.org/doc/html/rfc7901)

  The CHAIN option is used to request DNSSEC chain responses from
  authoritative servers.

  Option Format:

                        1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |        OPTION-CODE = 13       |       OPTION-LENGTH = 2       |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                      START-HASH                               |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  - START-HASH: 2 octets, DNSSEC algorithm identifier for the start of the chain
  """
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 2,
          data: start_hash :: 0..65535
        }

  defstruct code: OptionCode.new(13), length: 2, data: nil

  @spec new(integer()) :: t()
  def new(start_hash) do
    %__MODULE__{data: start_hash}
  end

  def from_iodata(<<13::16, 2::16, start_hash::16>>) do
    %__MODULE__{data: start_hash}
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option.Chain do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option.Chain{data: start_hash}) do
      <<13::16, 2::16, start_hash::16>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option.Chain do
    def to_string(%DNS.Message.EDNS0.Option.Chain{code: code, data: start_hash}) do
      "#{code}: #{start_hash}"
    end
  end
end
