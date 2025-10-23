defmodule DNS.Message.EDNS0.Option.ExtendedDNSError do
  @moduledoc """
  EDNS0.Option.ExtendedDNSError [RFC8914](https://datatracker.ietf.org/doc/html/rfc8914)

  The Extended DNS Error (EDE) option provides additional error
  information beyond the basic DNS RCODE.

  Option Format:

                        1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |        OPTION-CODE = 15       |       OPTION-LENGTH           |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |           INFO-CODE           |           EXTRA-TEXT          |
    |                                                               |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  - INFO-CODE: 2 octets, extended error code
  - EXTRA-TEXT: Variable length, human-readable error text (UTF-8)
  """
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 2..65535,
          data: {
            info_code :: 0..65535,
            extra_text :: binary()
          }
        }

  defstruct code: OptionCode.new(15), length: nil, data: nil

  @spec new({integer(), binary()}) :: t()
  def new({info_code, extra_text}) do
    len = 2 + byte_size(extra_text)
    %__MODULE__{length: len, data: {info_code, extra_text}}
  end

  def from_iodata(<<15::16, length::16, info_code::16, extra_text::binary-size(length - 2)>>) do
    %__MODULE__{length: length, data: {info_code, extra_text}}
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option.ExtendedDNSError do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option.ExtendedDNSError{
          data: {info_code, extra_text}
        }) do
      <<15::16, 2 + byte_size(extra_text)::16, info_code::16, extra_text::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option.ExtendedDNSError do
    def to_string(%DNS.Message.EDNS0.Option.ExtendedDNSError{
          code: code,
          data: {info_code, extra_text}
        }) do
      if extra_text == "" do
        "#{code}: #{info_code}"
      else
        "#{code}: #{info_code} #{extra_text}"
      end
    end
  end
end
