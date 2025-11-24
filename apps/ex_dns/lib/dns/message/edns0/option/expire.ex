defmodule DNS.Message.EDNS0.Option.Expire do
  @moduledoc """
  EDNS0.Option.Expire [RFC7314](https://datatracker.ietf.org/doc/html/rfc7314)

  The EDNS EXPIRE option is used to communicate the remaining time
  until a cached resource record expires.

  Option Format:

                        1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |        OPTION-CODE = 9        |       OPTION-LENGTH = 4       |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                       EXPIRE-TIME                             |
    |                                                               |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  - EXPIRE-TIME: 4 octets, remaining time until expiration in seconds
  """
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 4,
          data: expire_time :: 0..4_294_967_295
        }

  defstruct code: OptionCode.new(9), length: 4, data: nil

  @spec new(integer()) :: t()
  def new(expire_time) do
    %__MODULE__{data: expire_time}
  end

  def from_iodata(<<9::16, 4::16, expire_time::32>>) do
    %__MODULE__{data: expire_time}
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option.Expire do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option.Expire{data: expire_time}) do
      <<9::16, 4::16, expire_time::32>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option.Expire do
    def to_string(%DNS.Message.EDNS0.Option.Expire{code: code, data: expire_time}) do
      "#{code}: #{expire_time}s"
    end
  end
end
